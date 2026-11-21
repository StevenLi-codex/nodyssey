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
    private var retainedObservation: Task<Void, Never>?
    private var retainedRestart = 0
    private var retainedRefresh: Task<Void, Never>?
    private var refreshCompletion: NativeRefreshCompletion?
    private var refreshWatchdog: Task<Void, Never>?
    private let refreshTimeout: TimeInterval
    private var hasPagingValue = false
    private var observing = false
    private var isPaging: Bool { key?.operation == "feed" || key?.operation == "search.feed" }
    var hasValue: Bool { isPaging ? hasPagingValue : state.value != nil }

    deinit { retainedObservation?.cancel(); retainedRefresh?.cancel(); refreshWatchdog?.cancel() }

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, refreshTimeout: TimeInterval = 30) {
        self.now = now
        self.refreshTimeout = refreshTimeout
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
            // @Published emits even for equal assignments. Transport freshness is
            // independent of presentation changes; don't invalidate every row on
            // equal snapshots, load bookkeeping, or cancellation.
            // Paging emits an empty Idle/Loading presenter shell before Room's
            // result. It is not an accepted empty feed. Once loaded, an empty
            // result remains content even while its existing pager refreshes.
            if self.state.value == nil { self.hasPagingValue = false }
            else if self.isPaging, !next.nativeArray("items").isEmpty || next["refresh"]?.nativeString("status") == "NotLoading" {
                self.hasPagingValue = true
            }
            if self.value != next { self.value = next }
            if self.failure != self.state.failure { self.failure = self.state.failure }
            let pagingPending = self.isPaging && self.observing && self.state.value != nil && next["refresh"]?.nativeString("status") != "Error"
            let loading = !self.hasValue && self.state.failure == nil && (self.state.isLoading || pagingPending)
            let refreshing = self.state.isLoading && self.hasValue
            if self.isLoading != loading { self.isLoading = loading }
            if self.isRefreshing != refreshing { self.isRefreshing = refreshing }
            self.acceptRefreshObservation()
        }
    }

    private func prepare(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue]) {
        var identity = arguments
        // A transport handle changes on reattachment; board/sort/query/page do not.
        if name == "feed" || name == "search.feed" { identity.removeValue(forKey: "pagerId") }
        if name == "feed" {
            identity.removeValue(forKey: "page") // Resume page, not board/sort identity.
            identity.removeValue(forKey: "forceInitialRefresh") // One-shot transport policy, not feed identity.
        }
        let next = Key(app: ObjectIdentifier(app), generation: app.generation, operation: name, arguments: identity)
        if key != next { invalidate(); key = next }
        app.register(self)
    }

    /// A retained native page owns its subscription, not its appearance task.
    /// TabView cancels .task on departure even when its StateObject survives.
    /// Keep Kotlin's actual presenter/revision source alive until key change,
    /// explicit retry/cancel, identity revocation, or release of the page owner.
    /// Returns true only when a new observation (and paging ticket) is needed.
    @discardableResult
    func observeRetained(_ app: NativeAppModel, _ name: String, _ arguments: [String: JSONValue] = [:], restart: Int = 0) -> Bool {
        guard !Task.isCancelled else { return false }
        prepare(app, name, arguments)
        if retainedObservation != nil, retainedRestart == restart {
            refreshRetainedIfStale(app, name)
            return false
        }
        cancel()
        retainedRestart = restart
        pagingHandle = arguments["pagerId"]?.string
        isReplacingPagingWindow = (name == "feed" || name == "search.feed") && !value.nativeArray("items").isEmpty
        isLoading = !hasValue
        isRefreshing = hasValue
        let token = operation
        let state = self.state
        let transport = app.transport
        // Do not retain the store across the await: releasing its StateObject
        // must cancel the Kotlin handle instead of forming a self/task cycle.
        observing = true
        retainedObservation = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await state.observe(using: transport, operation: name, arguments: arguments)
            guard let self, self.operation == token else { return }
            self.retainedObservation = nil
            self.observing = false
            if self.isLoading { self.isLoading = false }
            if !Task.isCancelled, self.failure == nil {
                self.failure = NativeFailure(code: "OBSERVATION_ENDED", message: "Observation ended")
            }
            if self.failure != nil { self.receivedAt = nil }
            self.finishRetainedRefresh(false)
        }
        return true
    }

    /// Kotlin list revisions are local invalidations, not remote push. Revalidate
    /// an expired appearance without replacing its subscription or loaded rows.
    private func refreshRetainedIfStale(_ app: NativeAppModel, _ name: String, maximumAge: TimeInterval = 60) {
        let refresh: String
        switch name {
        case "notifications.list": refresh = "notifications.refresh"
        case "messages.list": refresh = "messages.refresh"
        default: return
        }
        guard hasValue, freshnessRemaining(maximumAge) <= 0 else { return }
        _ = beginRetainedRefresh(app, refresh, [:], mode: .revision)
    }

    /// Subscribe before dispatch and join TTL/toolbar/pull work through its actual
    /// observation terminal, not the command receipt. Each visual waiter owns only
    /// its continuation; cancelling it must not cancel another owner's request.
    @discardableResult
    func refreshRetained(_ app: NativeAppModel, _ operationName: String,
                         _ arguments: [String: JSONValue] = [:], mode: NativeRefreshCompletionMode) async -> Bool {
        guard !Task.isCancelled,
              let flight = beginRetainedRefresh(app, operationName, arguments, mode: mode) else { return false }
        let waiter = UUID()
        let token = operation
        let generation = app.generation
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else if let result = flight.result { continuation.resume(returning: result) }
                else { flight.waiters[waiter] = continuation }
            }
        } onCancel: {
            Task { @MainActor in flight.waiters.removeValue(forKey: waiter)?.resume(returning: false) }
        }
        return result && !Task.isCancelled && operation == token && app.generation == generation
    }

    private func beginRetainedRefresh(_ app: NativeAppModel, _ name: String,
                                      _ arguments: [String: JSONValue], mode: NativeRefreshCompletionMode) -> NativeRefreshCompletion? {
        guard let key, key.app == ObjectIdentifier(app), key.generation == app.generation,
              observing, retainedObservation != nil || state.value != nil else { return nil }
        let pager = arguments["pagerId"]?.string
        switch mode {
        case .paging:
            guard isPaging, name == "paging.refresh", let pager, pager == pagingHandle,
                  state.value?.nativeString("pagerId") == pager else { return nil }
        case .revision:
            guard (key.operation == "messages.list" && name == "messages.refresh") ||
                  (key.operation == "notifications.list" && name == "notifications.refresh") else { return nil }
        }
        if let flight = refreshCompletion {
            guard flight.operation == name, flight.arguments == arguments, flight.mode == mode else { return nil }
            return flight
        }
        // A completed observer cannot recover by refreshing its revision.
        guard state.failure == nil else { return nil }
        failure = nil
        // Only the explicitly advertised feed contract provides per-command Room receipts.
        // Search, legacy implementations and an ordinary false Boolean keep their old behavior.
        let receiptToken = mode == .paging && state.value?["refreshReceiptVersion"]?.int == 1 ? UUID().uuidString : nil
        let flight = NativeRefreshCompletion(operation: name, arguments: arguments, mode: mode,
                                             revision: state.valueRevision, pager: pager, receiptToken: receiptToken)
        refreshCompletion = flight
        let token = operation
        let transport = app.transport
        retainedRefresh = Task { [weak self] in
            do {
                // Read-only: bypass app mutation timestamp invalidation.
                var requestArguments = arguments
                if let receiptToken = flight.receiptToken { requestArguments["refreshToken"] = .string(receiptToken) }
                _ = try await transport.request(name, requestArguments)
                try Task.checkCancellation()
                guard let self, self.operation == token, self.refreshCompletion === flight else { return }
                flight.acknowledged = true
                self.finishRefreshIfReady(flight)
            } catch {
                guard let self, self.operation == token, self.refreshCompletion === flight else { return }
                self.finishRetainedRefresh(false, failure: error is CancellationError ? nil :
                    (error as? NativeFailure ?? .init(code: "TRANSPORT", message: "Refresh failed")))
            }
        }
        let timeout = max(0.001, min(refreshTimeout, 86_400))
        refreshWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            guard let self, self.operation == token, self.refreshCompletion === flight else { return }
            self.finishRetainedRefresh(false, failure: .init(code: "REFRESH_TIMEOUT", message: "Refresh timed out"))
        }
        return flight
    }

    private func acceptRefreshObservation() {
        guard let flight = refreshCompletion else { return }
        if let error = state.failure { finishRetainedRefresh(false, failure: error); return }
        guard state.valueRevision != flight.revision else { return }
        switch flight.mode {
        case .revision: flight.acceptedTerminal = true
        case .paging:
            guard let snapshot = state.value, snapshot.nativeString("pagerId") == flight.pager else { return }
            switch snapshot["refresh"]?.nativeString("status") {
            case "Loading":
                // A matching receipt has already proven presentation for this flight.
                // Only legacy completion follows the latest local load cycle.
                if flight.receiptToken == nil {
                    flight.sawLoading = true
                    flight.acceptedTerminal = false
                }
            case "NotLoading":
                if let token = flight.receiptToken {
                    if snapshot["refreshReceipt"]?.string == token { flight.acceptedTerminal = true }
                } else if flight.sawLoading { flight.acceptedTerminal = true }
            case "Error":
                if let token = flight.receiptToken, snapshot["refreshFailure"]?.string != token { return }
                let detail = snapshot["refresh"]?["error"]
                finishRetainedRefresh(false, failure: .init(code: detail?.nativeString("code") ?? "PAGING_REFRESH",
                    message: detail?.nativeString("message") ?? "Refresh failed"))
                return
            default: break
            }
        }
        finishRefreshIfReady(flight)
    }

    private func finishRefreshIfReady(_ flight: NativeRefreshCompletion) {
        if flight.acknowledged && flight.acceptedTerminal { finishRetainedRefresh(true) }
    }

    private func finishRetainedRefresh(_ success: Bool, failure error: NativeFailure? = nil) {
        guard let flight = refreshCompletion else { return }
        refreshCompletion = nil
        refreshWatchdog?.cancel(); refreshWatchdog = nil
        retainedRefresh?.cancel(); retainedRefresh = nil
        if let error { failure = error; receivedAt = nil }
        flight.resolve(success)
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
        observing = true
        await state.observe(using: app.transport, operation: name, arguments: arguments)
        guard operation == token else { return }
        observing = false
        if isLoading { isLoading = false }
        if !Task.isCancelled, failure == nil {
            failure = NativeFailure(code: "OBSERVATION_ENDED", message: "Observation ended")
        }
        if failure != nil { receivedAt = nil }
        finishRetainedRefresh(false)
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
        observing = false
        retainedObservation?.cancel(); retainedObservation = nil
        finishRetainedRefresh(false)
        retainedRefresh?.cancel(); retainedRefresh = nil
        refreshWatchdog?.cancel(); refreshWatchdog = nil
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
