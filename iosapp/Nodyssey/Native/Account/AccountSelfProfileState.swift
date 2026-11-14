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
    private var transport: (any NativeTransport)?
    private var isCurrent: (() -> Bool)?
    private var lifecycle = UUID()

    init() {
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
        invalidate()
        self.transport = transport
        let token = lifecycle
        let generation = currentGeneration()
        isCurrent = { currentGeneration() == generation }
        // Structured children inherit the screen's lifetime; neither path waits for
        // a non-null Room value (a newly signed-in user may have no cached row).
        async let observation: Void = observed.observe(using: transport, operation: "profile.self")
        await refresh()
        await observation
        if token == lifecycle, Task.isCancelled { invalidate() }
    }

    func refresh() async {
        guard let transport, isCurrent?() == true, !fetched.isLoading else { return }
        await fetched.load(using: transport, operation: "profile.self", arguments: ["refresh": .bool(true)])
    }

    func invalidate() {
        lifecycle = UUID(); isCurrent = nil; transport = nil
        observed.invalidate(); fetched.invalidate()
        snapshot = .null; snapshotFailure = nil; loading = false
    }
}
