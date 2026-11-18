import Foundation
import Combine
import NodysseyNativeCore

/// Room remains the visible source of truth. Network refresh owns a DIFFERENT
/// request state: loading it must never cancel the long-lived Room observation.
@MainActor
final class AccountSelfProfileState: ObservableObject {
    @Published private var snapshot: JSONValue = .null
    @Published private var snapshotFailure: NativeFailure?
    @Published private var loading = false
    // App generation publishes before SwiftUI restarts .task. Hide the previous
    // identity synchronously in that render, not only after the new task runs.
    var value: JSONValue { isCurrent?() == true ? snapshot : .null }
    var failure: NativeFailure? { isCurrent?() == true ? snapshotFailure : nil }
    var isLoading: Bool { isCurrent?() == true && loading }
    private let observed = NativeRequestState()
    private let fetched = NativeRequestState()
    private let refreshFlight = AccountReadFlightState()
    private var transport: (any NativeTransport)?
    private var isCurrent: (() -> Bool)?
    private var lifecycle = UUID()
    private let now: () -> TimeInterval
    private var fetchedAt: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        observed.onChange = { [weak self] in self?.publish() }
        fetched.onChange = { [weak self] in self?.publish() }
    }

    private func publish() {
        guard isCurrent?() == true else { return }
        snapshot = observed.value ?? .null
        snapshotFailure = fetched.failure ?? observed.failure
        loading = observed.isLoading || fetched.isLoading
    }

    func run(using transport: any NativeTransport, currentGeneration: @escaping () -> Int) async {
        guard !Task.isCancelled else { return }
        if isCurrent?() != true { invalidate() }
        else { observed.cancel(); fetched.cancel(); refreshFlight.cancel() }
        lifecycle = UUID()
        self.transport = transport
        let token = lifecycle
        let generation = currentGeneration()
        isCurrent = { currentGeneration() == generation }
        // Reattach Room, but keep the accepted snapshot during the handoff. A
        // short tab/route return is not an explicit network refresh.
        async let observation: Void = observed.observe(using: transport, operation: "profile.self")
        if fetchedAt.map({ now() - $0 >= 60 }) ?? true { await refresh() }
        await observation
        if token == lifecycle, Task.isCancelled {
            observed.cancel(); fetched.cancel(); refreshFlight.cancel()
        }
    }

    @discardableResult func refresh() async -> Bool {
        guard !Task.isCancelled, let transport, isCurrent?() == true else { return false }
        let token = lifecycle
        return await refreshFlight.run(key: token.uuidString, current: { [weak self] in
            self?.lifecycle == token && self?.isCurrent?() == true
        }) { [self] accepted in
            let revision = fetched.valueRevision
            await fetched.load(using: transport, operation: "profile.self", arguments: ["refresh": .bool(true)])
            guard accepted() else { return false }
            if fetched.valueRevision != revision { fetchedAt = now(); return true }
            if fetched.failure != nil { fetchedAt = nil }
            return false
        }
    }

    func invalidate() {
        lifecycle = UUID(); isCurrent = nil; transport = nil; fetchedAt = nil
        refreshFlight.cancel(); observed.invalidate(); fetched.invalidate()
        snapshot = .null; snapshotFailure = nil; loading = false
    }

    func markStale(after operation: String) {
        if operation == "attendance.sign" || operation.hasPrefix("account.") { fetchedAt = nil }
    }
}
