import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@MainActor private final class RefreshCallbackProbe {
    var requests: [(@Sendable (String) -> Void)] = []
    var observations: [(@Sendable (String) -> Void)] = []
    var cancellations = 0
    lazy var transport = CallbackNativeTransport(request: { [weak self] _, _, reply in
        self?.requests.append(reply)
        return NativeCancellation { [weak self] in Task { @MainActor in self?.cancellations += 1 } }
    }, observe: { [weak self] _, _, reply in
        self?.observations.append(reply)
        return NativeCancellation { }
    })
}

@Suite @MainActor struct NativeRefreshStoreTests {
    @Test func callbackTransportCancellationIsPerWaiterAndLateReceiptCannotReviveIdentity() async throws {
        let probe = RefreshCallbackProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore()
        store.observeRetained(app, "messages.list")
        try await eventually { probe.observations.count == 1 }
        probe.observations[0](#"{"ok":true,"data":[]}"#)
        try await eventually { store.hasValue }
        let first = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { probe.requests.count == 1 }
        let joined = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        for _ in 0..<30 { await Task.yield() }
        first.cancel()
        #expect(await first.value == false)
        #expect(probe.cancellations == 0, "A cancelled visual waiter cannot cancel shared Kotlin work")
        probe.requests[0](#"{"ok":true,"data":null}"#)
        probe.observations[0](#"{"ok":true,"data":[]}"#)
        #expect(await joined.value == true)
        let late = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { probe.requests.count == 2 }
        store.invalidate()
        #expect(await late.value == false)
        try await eventually { probe.cancellations == 2 }
        probe.requests[1](#"{"ok":true,"data":null}"#)
        probe.observations[0](#"{"ok":true,"data":["old identity"]}"#)
        for _ in 0..<30 { await Task.yield() }
        #expect(store.value == .null && store.failure == nil)
    }

    @Test func endingNonRetainedObservationResolvesRefreshImmediately() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore(refreshTimeout: 0.05)
        let observing = Task { await store.observe(app, "messages.list") }
        try await eventually { transport.hasStream("messages.list") }
        transport.emit("messages.list", .array([]))
        try await eventually { store.hasValue }
        let refresh = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { transport.hasRequest("messages.refresh") }
        transport.resolve("messages.refresh", .success(.null))
        transport.finish("messages.list")
        await observing.value
        #expect(await refresh.value == false)
        #expect(store.failure?.code == "OBSERVATION_ENDED", "An ended observation must terminate the flight before its watchdog")
        store.cancel()
    }

    private func snapshot(_ status: String, pager: String = "pager") -> JSONValue {
        .object(["pagerId": .string(pager), "items": .array([.string("cached")]),
                 "refresh": .object(["status": .string(status)])])
    }

    @Test func pagingRequiresNewLoadingThenTerminalEvenForEqualFinalData() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        store.observeRetained(app, "feed", ["pagerId": .string("pager")])
        try await eventually { transport.hasStream("feed") }
        transport.emit("feed", snapshot("NotLoading"))
        try await eventually { store.hasValue }
        var result: Bool?
        let refresh = Task { result = await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        try await eventually { transport.hasRequest("paging.refresh") }
        transport.resolve("paging.refresh", .success(.null))
        transport.emit("feed", snapshot("NotLoading"))
        for _ in 0..<100 { await Task.yield() }
        #expect(result == nil, "The old NotLoading or an unchanged NotLoading emission cannot finish a new refresh")
        // Both callbacks can precede any SwiftUI body publication.
        transport.emit("feed", snapshot("Loading"))
        transport.emit("feed", snapshot("NotLoading"))
        await refresh.value
        #expect(result == true)
        #expect(store.value == snapshot("NotLoading"))
        #expect(transport.arguments(for: "paging.refresh").count == 1)
        store.cancel()
    }

    @Test func ttlAndTwoVisualWaitersShareEqualDataCompletionWhileOneCancels() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        store.observeRetained(app, "notifications.list")
        try await eventually { transport.hasStream("notifications.list") }
        let rows = JSONValue.array([.string("cached")])
        transport.emit("notifications.list", rows)
        try await eventually { store.hasValue }
        uptime = 160
        store.observeRetained(app, "notifications.list")
        try await eventually { transport.hasRequest("notifications.refresh") }
        var first: Bool?
        var second: Bool?
        let pull = Task { first = await store.refreshRetained(app, "notifications.refresh", mode: .revision) }
        let toolbar = Task { second = await store.refreshRetained(app, "notifications.refresh", mode: .revision) }
        for _ in 0..<30 { await Task.yield() }
        pull.cancel()
        await pull.value
        #expect(first == false && second == nil)
        #expect(transport.arguments(for: "notifications.refresh").count == 1)
        transport.resolve("notifications.refresh", .success(.null))
        for _ in 0..<30 { await Task.yield() }
        #expect(second == nil, "Receipt is not observed completion")
        uptime = 161
        transport.emit("notifications.list", rows)
        await toolbar.value
        #expect(second == true && store.value == rows)
        uptime = 220
        store.observeRetained(app, "notifications.list")
        #expect(transport.arguments(for: "notifications.refresh").count == 1, "Accepted equal rows renew the 60-second TTL; read-only receipt does not mark them stale")
        store.cancel()
    }

    @Test func observationCanCompleteBeforeReceiptButReceiptStillRequired() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        store.observeRetained(app, "messages.list")
        try await eventually { transport.hasStream("messages.list") }
        transport.emit("messages.list", .array([]))
        try await eventually { store.hasValue }
        var result: Bool?
        let refresh = Task { result = await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { transport.hasRequest("messages.refresh") }
        transport.emit("messages.list", .array([]))
        for _ in 0..<100 { await Task.yield() }
        #expect(result == nil)
        transport.resolve("messages.refresh", .success(.null))
        await refresh.value
        #expect(result == true)
        store.cancel()
    }

    @Test(arguments: ["Error", "observation", "cancel", "invalidate", "identity", "timeout"])
    func failuresResolveAllWaitersWithoutErasingRowsExceptIdentity(kind: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore(refreshTimeout: kind == "timeout" ? 0.03 : 30)
        store.observeRetained(app, "feed", ["pagerId": .string("pager")])
        try await eventually { transport.hasStream("feed") }
        transport.emit("feed", snapshot("NotLoading"))
        try await eventually { store.hasValue }
        let first = Task { await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        try await eventually { transport.hasRequest("paging.refresh") }
        let joined = Task { await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        for _ in 0..<30 { await Task.yield() }
        transport.resolve("paging.refresh", .success(.null))
        switch kind {
        case "Error": transport.emit("feed", snapshot("Loading")); transport.emit("feed", snapshot("Error"))
        case "observation": transport.finish("feed", error: NativeFailure(code: "NETWORK", message: "offline"))
        case "cancel": store.cancel()
        case "invalidate": store.invalidate()
        case "identity": app.session = .object(["identityEpoch": .string("B"), "isSignedIn": .bool(true), "generation": .integer(2)])
        default: break
        }
        #expect(await first.value == false)
        #expect(await joined.value == false)
        if kind == "invalidate" || kind == "identity" { #expect(store.value == .null) }
        else { #expect(store.value.nativeArray("items") == [.string("cached")]) }
        if kind == "timeout" { #expect(store.failure?.code == "REFRESH_TIMEOUT") }
        if kind == "Error" { #expect(store.failure?.code == "PAGING_REFRESH") }
        if kind == "observation" { #expect(store.failure?.code == "NETWORK") }
        #expect(transport.arguments(for: "paging.refresh").count == 1, "Failure/watchdog cannot issue another request")
        store.cancel()
    }

    @Test func staleFailureClearsOnlyWhenNewRefreshIsAdmitted() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        store.observeRetained(app, "messages.list")
        try await eventually { transport.hasStream("messages.list") }
        transport.emit("messages.list", .array([]))
        try await eventually { store.hasValue }
        let failed = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { transport.hasRequest("messages.refresh") }
        transport.resolve("messages.refresh", .failure(NativeFailure(code: "NETWORK", message: "offline")))
        #expect(await failed.value == false)
        #expect(store.failure?.code == "NETWORK")
        #expect(await store.refreshRetained(app, "paging.refresh", mode: .paging) == false)
        #expect(store.failure?.code == "NETWORK")
        let retry = Task { await store.refreshRetained(app, "messages.refresh", mode: .revision) }
        try await eventually { transport.arguments(for: "messages.refresh").count == 2 }
        #expect(store.failure == nil)
        transport.resolve("messages.refresh", .success(.null))
        transport.emit("messages.list", .array([]))
        #expect(await retry.value == true)
        #expect(store.failure == nil)
        store.cancel()
    }

    @Test func wrongPagerRefusesWithoutDispatchAndQueuedOldGenerationCannotSucceed() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        store.observeRetained(app, "feed", ["pagerId": .string("pager")])
        try await eventually { transport.hasStream("feed") }
        transport.emit("feed", snapshot("NotLoading"))
        try await eventually { store.hasValue }
        #expect(await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("old")], mode: .paging) == false)
        #expect(transport.arguments(for: "paging.refresh").isEmpty)
        let refresh = Task { await store.refreshRetained(app, "paging.refresh", ["pagerId": .string("pager")], mode: .paging) }
        try await eventually { transport.hasRequest("paging.refresh") }
        store.invalidate()
        transport.resolve("paging.refresh", .success(.null))
        transport.emit("feed", snapshot("Loading"))
        transport.emit("feed", snapshot("NotLoading"))
        #expect(await refresh.value == false)
        for _ in 0..<30 { await Task.yield() }
        #expect(store.value == .null && store.failure == nil)
    }

    @Test func acknowledgedRefreshRemainsInFlightUntilListData() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        store.observeRetained(app, "messages.list")
        try await eventually { transport.hasStream("messages.list") }
        transport.emit("messages.list", .array([.string("cached")]))
        try await eventually { store.hasValue }
        uptime = 160
        store.observeRetained(app, "messages.list")
        try await eventually { transport.hasRequest("messages.refresh") }
        transport.resolve("messages.refresh", .success(.null))
        for _ in 0..<100 { await Task.yield() }
        // An appearance clock advancing does not complete the pending list fetch.
        uptime = 221
        store.observeRetained(app, "messages.list")
        for _ in 0..<100 { await Task.yield() }
        #expect(transport.arguments(for: "messages.refresh").count == 1,
                "Refresh acknowledgement must stay coalesced until actual list data or watchdog termination")
        store.cancel()
        transport.resolve("messages.refresh", .success(.null))
    }
}
