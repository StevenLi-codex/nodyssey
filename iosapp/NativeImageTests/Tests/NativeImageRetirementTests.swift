import Foundation
import Testing
@testable import NativeImage

/// Per-invocation gates model synchronous ImageIO that cannot drain until explicitly released.
final class RetirementDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [DispatchSemaphore] = []
    private var active = 0
    private var peak = 0
    private var cancelled = 0
    private let cooperative: Bool

    init(cooperative: Bool = false) { self.cooperative = cooperative }
    var count: Int { lock.lock(); defer { lock.unlock() }; return gates.count }
    var maximumRunning: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancelled }

    func decode(_ data: Data, size: Int?) -> UIImage? {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        gates.append(gate)
        active += 1
        peak = max(peak, active)
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if cooperative {
            while gate.wait(timeout: .now() + .milliseconds(1)) == .timedOut {
                if Task.isCancelled {
                    lock.lock(); cancelled += 1; lock.unlock()
                    return nil
                }
            }
        } else {
            gate.wait()
        }
        return NativeImageDecoder.decode(data, maxPixel: size)
    }

    func release(_ index: Int) {
        lock.lock(); let gate = gates.indices.contains(index) ? gates[index] : nil; lock.unlock()
        gate?.signal()
    }

    func releaseAll() {
        lock.lock(); let pending = gates; lock.unlock()
        for gate in pending { gate.signal() }
    }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

@MainActor private func settleRequests() async throws {
    // Let the off-main digest and main-actor continuation registration complete while workers stay held.
    try await Task.sleep(nanoseconds: 20_000_000)
}

@Suite(.serialized) @MainActor struct NativeImageRetirementTests {
    private let owner = NSObject()
    private func scope(_ epoch: String) -> NativeImageScope {
        NativeImageScope(appIdentity: ObjectIdentifier(owner), identityEpoch: epoch, boundaryEpoch: epoch,
            boundaryPhase: "READY", generation: 1, site: "NODESEEK", siteOrigin: nil, wifiOnly: false)
    }

    @Test func lastWaiterCancellationStopsCooperativeWorkersAndFreshSameKeyCanDecode() async throws {
        let probe = RetirementDecodeProbe(cooperative: true)
        let pipeline = NativeImagePipeline(maxConcurrent: 2, decode: { probe.decode($0, size: $1) })
        defer { probe.releaseAll() }
        let data = raster(width: 47)
        var firstReturned = false, secondReturned = false
        let first = Task { let image = await pipeline.image(data, scope: nil); firstReturned = true; return image }
        let second = Task { let image = await pipeline.image(raster(width: 48), scope: nil); secondReturned = true; return image }
        #expect(try await eventually { probe.count == 2 })
        first.cancel()
        second.cancel()
        #expect(try await eventually { firstReturned && secondReturned })
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        // Model the GIF decoder's between-frame cancellation checks: abandoned work must drain
        // without releasing its normal-completion gate or keeping the entire budget occupied.
        try #require(try await eventually { probe.cancellationCount == 2 })
        let fresh = Task { await pipeline.image(data, scope: nil) }
        let other = Task { await pipeline.image(raster(width: 49), scope: nil) }
        try #require(try await eventually { probe.count == 4 })
        probe.releaseAll()
        let image = try #require(await fresh.value)
        #expect(await other.value != nil)
        #expect(await pipeline.image(data, scope: nil) === image)
        #expect(probe.count == 4)
        #expect(probe.maximumRunning == 2)
    }

    @Test func lastWaiterCancellationRetiresUncooperativeSameKeyAndFencesStaleFinish() async throws {
        let probe = RetirementDecodeProbe()
        let pipeline = NativeImagePipeline(maxConcurrent: 2, decode: { probe.decode($0, size: $1) })
        defer { probe.releaseAll() }
        let data = raster(width: 50)
        var oldReturned = false
        let old = Task { let image = await pipeline.image(data, scope: nil); oldReturned = true; return image }
        #expect(try await eventually { probe.count == 1 })
        old.cancel()
        #expect(try await eventually { oldReturned })
        #expect(await old.value == nil)
        var freshReturned = false
        let fresh = Task { let image = await pipeline.image(data, scope: nil); freshReturned = true; return image }
        // A cancelled, uncooperative task is not joinable: one remaining slot can run its replacement.
        try #require(try await eventually { probe.count == 2 })
        let other = Task { await pipeline.image(raster(width: 51), scope: nil) }
        try await settleRequests()
        #expect(probe.count == 2)
        probe.release(0) // the retired same-key worker finishes while the replacement is RUNNING
        #expect(try await eventually { probe.count == 3 })
        #expect(!freshReturned)
        probe.release(1)
        #expect(try await eventually { freshReturned })
        let image = try #require(await fresh.value)
        probe.releaseAll()
        #expect(await other.value != nil)
        #expect(await pipeline.image(data, scope: nil) === image)
        #expect(probe.count == 3)
        #expect(probe.maximumRunning == 2)
    }

    @Test func queuedScopeAToBToABeforeWorkersDrainSchedulesFreshDecode() async throws {
        let probe = RetirementDecodeProbe()
        let pipeline = NativeImagePipeline(maxConcurrent: 2, decode: { probe.decode($0, size: $1) })
        defer { probe.releaseAll() }
        let a = scope("A"), b = scope("B")
        let first = Task { await pipeline.image(raster(width: 41), scope: a) }
        let second = Task { await pipeline.image(raster(width: 42), scope: a) }
        #expect(try await eventually { probe.count == 2 })
        let data = raster(width: 43)
        var queuedReturned = false
        let queued = Task { let image = await pipeline.image(data, scope: a); queuedReturned = true; return image }
        try await settleRequests()
        #expect(!queuedReturned)
        #expect(probe.count == 2)
        pipeline.admitScope(b)
        #expect(try await eventually { queuedReturned })
        #expect(await queued.value == nil)
        var freshReturned = false
        let fresh = Task { let image = await pipeline.image(data, scope: a); freshReturned = true; return image }
        try await settleRequests()
        #expect(!freshReturned)
        #expect(probe.count == 2)
        probe.release(0)
        #expect(try await eventually { probe.count == 3 })
        probe.releaseAll()
        #expect(await fresh.value != nil)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
        #expect(probe.count == 3)
        #expect(probe.maximumRunning == 2)
    }

    @Test func runningScopeAToBToARetiresUncooperativeWorkerWithoutReleasingItsSlot() async throws {
        let probe = RetirementDecodeProbe()
        let pipeline = NativeImagePipeline(maxConcurrent: 2, decode: { probe.decode($0, size: $1) })
        defer { probe.releaseAll() }
        let a = scope("A"), b = scope("B"), data = raster(width: 44)
        let old = Task { await pipeline.image(data, scope: a) }
        #expect(try await eventually { probe.count == 1 })
        let blocker = Task { await pipeline.image(raster(width: 45), scope: a) }
        #expect(try await eventually { probe.count == 2 })
        pipeline.admitScope(b)
        #expect(await old.value == nil)
        #expect(await blocker.value == nil)
        var freshReturned = false
        let fresh = Task { let image = await pipeline.image(data, scope: a); freshReturned = true; return image }
        try await settleRequests()
        #expect(!freshReturned)
        let other = Task { await pipeline.image(raster(width: 46), scope: a) }
        try await settleRequests()
        #expect(probe.count == 2) // cancelled synchronous workers still consume both slots
        probe.release(0) // stale same-key finish must not remove/publish the queued replacement
        #expect(try await eventually { probe.count == 3 })
        #expect(!freshReturned)
        #expect(probe.count == 3) // the second revoked worker still owns its slot
        probe.release(2)
        #expect(try await eventually { freshReturned })
        let image = try #require(await fresh.value)
        #expect(try await eventually { probe.count == 4 })
        probe.releaseAll()
        #expect(await other.value != nil)
        #expect(await pipeline.image(data, scope: a) === image)
        #expect(probe.count == 4)
        #expect(probe.maximumRunning == 2)
    }
}
