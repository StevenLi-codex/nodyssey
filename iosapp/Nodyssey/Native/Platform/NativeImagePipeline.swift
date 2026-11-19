import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/// Only entered after NativePlatform.image has admitted and returned THIS access's bytes.
/// No URL lookup exists: a Swift memory hit must not bypass Kotlin's private/Wi-Fi/offline policy.
@MainActor
final class NativeImagePipeline {
    static let shared = NativeImagePipeline()
    private struct Key: Hashable {
        let scope: NativeImageScope?
        let digest: Data
        let maxPixel: Int?
    }
    private struct Entry { let image: UIImage; let cost: Int; var use: UInt64 }
    private final class Flight {
        let data: Data
        var waiters: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
        var worker: Task<UIImage?, Never>?
        var revoked = false
        init(_ data: Data) { self.data = data }
    }
    private var entries: [Key: Entry] = [:]
    private var flights: [Key: Flight] = [:]
    private var queue: [Key] = []
    // Running workers own slots by identity, independently of the joinable keyed flights.
    // Retired synchronous ImageIO work keeps its slot until its actual completion.
    private var running: [ObjectIdentifier: Flight] = [:]
    private var clock: UInt64 = 0
    private var totalCost = 0
    private let costLimit: Int
    private let countLimit: Int
    private let decode: @Sendable (Data, Int?) -> UIImage?
    private let maxConcurrent: Int

    init(maxConcurrent: Int = 2, costLimit: Int = 48 * 1024 * 1024, countLimit: Int = 64,
         decode: @escaping @Sendable (Data, Int?) -> UIImage? = { NativeImageDecoder.decode($0, maxPixel: $1) }) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.costLimit = max(0, costLimit)
        self.countLimit = max(1, countLimit)
        self.decode = decode
        #if canImport(UIKit)
        memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.removeCachedImages() }
            }
        #endif
    }

    private var memoryObserver: NSObjectProtocol?

    func removeCachedImages() {
        entries.removeAll()
        totalCost = 0
    }

    private var currentScope: NativeImageScope?

    /// Called by the view owner on scope changes even before another byte access completes.
    func admitScope(_ scope: NativeImageScope?) {
        guard let scope, currentScope != scope else { return }
        currentScope = scope
        // There is one installed app graph. Purging other app instances too is conservative,
        // bounded, and avoids retaining a dictionary of dead process-local owner identities.
        entries.removeAll()
        totalCost = 0
        let revoked = flights.values
        flights.removeAll()
        queue.removeAll()
        for flight in revoked {
            flight.revoked = true
            flight.worker?.cancel()
            for waiter in flight.waiters.values { waiter.resume(returning: nil) }
            flight.waiters.removeAll()
        }
    }

    func image(_ data: Data, scope: NativeImageScope?, maxPixel: Int? = nil) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        admitScope(scope)
        // Hash off-main too: large original files must not stall the UI actor.
        let digest = await Task.detached(priority: .userInitiated) { Data(SHA256.hash(data: data)) }.value
        guard !Task.isCancelled, scope == nil || currentScope == scope else { return nil }
        let key = Key(scope: scope, digest: digest, maxPixel: maxPixel)
        clock &+= 1
        if var entry = entries[key] {
            entry.use = clock
            entries[key] = entry
            return entry.image
        }
        let waiter = UUID()
        let image: UIImage? = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let flight = flights[key] {
                    guard !flight.revoked else { continuation.resume(returning: nil); return }
                    flight.waiters[waiter] = continuation
                } else {
                    let flight = Flight(data)
                    flight.waiters[waiter] = continuation
                    flights[key] = flight
                    queue.append(key)
                    drain()
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key, waiter: waiter) }
        })
        return Task.isCancelled || (scope != nil && currentScope != scope) ? nil : image
    }

    private func cancel(_ key: Key, waiter: UUID) {
        guard let flight = flights[key],
              let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(returning: nil)
        guard flight.waiters.isEmpty else { return }
        // No live owner can join a cancelled worker. Retire its key immediately so a fresh
        // admitted request gets a replacement, but retain its running slot until ImageIO drains.
        flights.removeValue(forKey: key)
        queue.removeAll { $0 == key }
        flight.revoked = true
        flight.worker?.cancel()
    }

    private func drain() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let flight = flights[key] else { continue }
            guard !flight.revoked, !flight.waiters.isEmpty else { flights.removeValue(forKey: key); continue }
            running[ObjectIdentifier(flight)] = flight
            let data = flight.data
            let decode = self.decode
            let worker = Task.detached(priority: .userInitiated) { decode(data, key.maxPixel) }
            flight.worker = worker
            Task { [weak self] in
                let image = await worker.value
                self?.finish(key, flight: flight, image: image)
            }
        }
    }

    private func finish(_ key: Key, flight: Flight, image: UIImage?) {
        guard running.removeValue(forKey: ObjectIdentifier(flight)) != nil else { return }
        // An old same-key worker must never remove or publish into its replacement.
        if flights[key] === flight {
            flights.removeValue(forKey: key)
            if let image, !flight.revoked, !flight.waiters.isEmpty { insert(image, key: key) }
            for waiter in flight.waiters.values { waiter.resume(returning: flight.revoked ? nil : image) }
            flight.waiters.removeAll()
        }
        drain()
    }

    private func insert(_ image: UIImage, key: Key) {
        var seen = Set<ObjectIdentifier>()
        let cost = (image.images ?? [image]).reduce(0) { sum, frame in
            guard seen.insert(ObjectIdentifier(frame)).inserted, let cg = frame.cgImage else { return sum }
            return sum + cg.bytesPerRow * cg.height
        }
        guard cost > 0, cost <= costLimit else { return }
        while entries.count >= countLimit || totalCost + cost > costLimit {
            guard let victim = entries.min(by: { $0.value.use < $1.value.use }) else { break }
            totalCost -= victim.value.cost
            entries.removeValue(forKey: victim.key)
        }
        entries[key] = Entry(image: image, cost: cost, use: clock)
        totalCost += cost
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        for flight in running.values { flight.worker?.cancel() }
        for flight in flights.values {
            flight.worker?.cancel()
            for waiter in flight.waiters.values { waiter.resume(returning: nil) }
        }
    }
}
