import Foundation
import Combine
import NodysseyNativeCore

/// One transient presentation snapshot, not a second repository or disk cache.
/// The core owns transport cancellation and stale-publication suppression.
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isReplacingPagingWindow = false
    private let state = NativeRequestState()
    private var operation = UUID()
    private struct Key: Equatable {
        let app: ObjectIdentifier
        let generation: Int
        let operation: String
        let arguments: [String: JSONValue]
    }
    private var key: Key?
    private let now: () -> TimeInterval
    private var receivedAt: TimeInterval?
    private var valueRevision: UInt64 = 0
    private var loadingTask: Task<Void, Never>?
    private var freshnessWait: Task<Void, Never>?
    private var pagingHandle: String?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        state.onChange = { [weak self] in
            guard let self else { return }
            if self.valueRevision != self.state.valueRevision {
                self.valueRevision = self.state.valueRevision
                self.receivedAt = self.now()
            }
            var next = self.state.value ?? .null
            if self.isReplacingPagingWindow, !self.value.nativeArray("items").isEmpty {
                if next.nativeArray("items").isEmpty && next["refresh"]?.nativeString("status") != "NotLoading" {
                    // A restarted Kotlin pager first emits its empty Loading window.
                    // Keep the last loaded rows, but expose the NEW handle/load states.
                    var retained = next.object ?? [:]
                    for field in ["items", "placeholdersBefore", "placeholdersAfter", "itemCount", "totalPages"] {
                        retained[field] = self.value[field]
                    }
                    next = .object(retained)
                } else if next.nativeString("pagerId") == self.pagingHandle { self.isReplacingPagingWindow = false }
            }
            self.value = next
            self.failure = self.state.failure
            // Empty and JSON null are responses too; only absence owns skeletons.
            self.isLoading = self.state.isLoading && self.state.value == nil
            self.isRefreshing = self.state.isLoading && self.state.value != nil
        }
    }

    private func prepare(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue]) {
        var identity = arguments
        // A transport handle changes on reattachment; board/sort/query/page do not.
        if name == "feed" || name == "search.feed" { identity.removeValue(forKey: "pagerId") }
        if name == "feed" { identity.removeValue(forKey: "page") } // Resume page, not board/sort identity.
        let next = Key(app: ObjectIdentifier(app), generation: app.generation, operation: name, arguments: identity)
        if key != next { invalidate(); key = next }
        app.register(self)
    }

    /// Explicit user refresh/readback remains authoritative, regardless of age.
    func load(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue] = [:]) async {
        prepare(app, name, arguments)
        cancel()
        await performLoad(app, name, arguments)
    }

    /// Appearance-only refresh: coalesce in-flight work and skip fresh responses.
    /// Cancellation never stamps an old value as freshly fetched.
    func loadIfStale(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue] = [:], maximumAge: TimeInterval = 60) async {
        guard !Task.isCancelled else { return }
        prepare(app, name, arguments)
        if let loadingTask {
            await withTaskCancellationHandler { await loadingTask.value } onCancel: { loadingTask.cancel() }
            return
        }
        guard freshnessRemaining(maximumAge) <= 0 else { return }
        cancel()
        await performLoad(app, name, arguments)
    }

    private func performLoad(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue]) async {
        guard !Task.isCancelled else { return }
        let token = operation
        let task = Task { await state.load(using: app.transport, operation: name, arguments: arguments) }
        loadingTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard operation == token else { return }
        loadingTask = nil
        if failure != nil { receivedAt = nil }
    }

    private func freshnessRemaining(_ maximumAge: TimeInterval) -> TimeInterval {
        guard let receivedAt, failure == nil else { return 0 }
        return max(0, min(maximumAge, maximumAge - max(0, now() - receivedAt)))
    }

    /// Network-backed observation: keep a fresh snapshot on return without
    /// starting a second fetch. Only the visible screen owns this cancellable
    /// wait; at expiry reconnect to the existing Kotlin revision/Flow source.
    func observeCached(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue] = [:], maximumAge: TimeInterval = 60) async {
        guard !Task.isCancelled else { return }
        prepare(app, name, arguments)
        cancel()
        let token = operation
        let remaining = freshnessRemaining(maximumAge)
        if remaining > 0 {
            let sleeper = Task<Void, Never> {
                do { try await Task.sleep(nanoseconds: UInt64(min(remaining, 86_400) * 1_000_000_000)) }
                catch { } // Mutation wake-up or departure, checked below.
            }
            freshnessWait = sleeper
            await withTaskCancellationHandler { await sleeper.value } onCancel: { sleeper.cancel() }
            guard operation == token, !Task.isCancelled else { return }
            freshnessWait = nil
        }
        guard operation == token, !Task.isCancelled else { return }
        await observePrepared(app, name, arguments, token: token)
    }

    func observe(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue] = [:]) async {
        guard !Task.isCancelled else { return }
        prepare(app, name, arguments)
        pagingHandle = arguments["pagerId"]?.string
        isReplacingPagingWindow = (name == "feed" || name == "search.feed") && !value.nativeArray("items").isEmpty
        cancel()
        await observePrepared(app, name, arguments, token: operation)
    }

    private func observePrepared(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue], token: UUID) async {
        await state.observe(using: app.transport, operation: name, arguments: arguments)
        guard operation == token else { return }
        if !Task.isCancelled, failure == nil {
            failure = NativeFailure(code: "OBSERVATION_ENDED", message: "Observation ended")
        }
        if failure != nil { receivedAt = nil }
    }

    func markStale() {
        receivedAt = nil
        freshnessWait?.cancel()
    }

    /// Revisions remain Kotlin-owned. A dormant freshness wait cannot consume
    /// those emissions, so dispatched writes (including uncertain failure) wake it.
    func invalidateFreshness(after mutation: String) {
        let affected: [String]
        switch mutation {
        case "notifications.refresh", "notifications.read", "notifications.readAll":
            affected = ["notifications.list", "notifications.counts"]
        case "messages.refresh", "messages.read", "messages.readAll", "messages.send":
            affected = ["messages.list", "messages.thread", "notifications.counts"]
        case "attendance.sign": affected = ["attendance.status"]
        default: return
        }
        if let name = key?.operation, affected.contains(name) { markStale() }
    }

    /// Temporary navigation-away: retire callbacks, keep this identity's rows.
    func cancel() {
        operation = UUID()
        freshnessWait?.cancel(); freshnessWait = nil
        loadingTask?.cancel(); loadingTask = nil
        state.cancel()
    }

    /// Account/site revocation or changed request key: never keep private rows.
    func invalidate() {
        pagingHandle = nil
        isReplacingPagingWindow = false
        cancel()
        key = nil; receivedAt = nil
        state.invalidate()
    }
}
