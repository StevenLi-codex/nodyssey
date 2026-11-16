import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@MainActor private final class RetentionProbe {
    struct Call {
        let name: String
        let reply: @Sendable (String) -> Void
    }
    var requests: [Call] = []
    var observations: [Call] = []
    var requestCancels = 0
    var observationCancels = 0
    lazy var transport = CallbackNativeTransport(request: { [weak self] name, _, reply in
        self?.requests.append(Call(name: name, reply: reply))
        return NativeCancellation { [weak self] in Task { @MainActor [weak self] in self?.requestCancels += 1 } }
    }, observe: { [weak self] name, _, reply in
        self?.observations.append(Call(name: name, reply: reply))
        return NativeCancellation { [weak self] in Task { @MainActor [weak self] in self?.observationCancels += 1 } }
    })
}

@Suite @MainActor struct StoreRetentionTests {
    @Test func registeredPresentationOwnerIsRevokedSynchronouslyBeforeGenerationChanges() {
        let app = NativeAppModel(transport: ControlledTransport())
        app.session = .object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)])
        let owner = NSObject()
        let generation = app.generation
        var revokedAt: Int?
        app.registerRetainedOwner(owner, invalidate: { revokedAt = app.generation })
        app.session = .object(["identityEpoch": .string("B"), "isSignedIn": .bool(false), "generation": .integer(2)])
        #expect(revokedAt == generation)
    }

    @Test func pagingReturnKeepsWindowUntilReplacementAndUsesFreshHandle() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let rows = JSONValue.array([.object(["page": .integer(4), "summary": .object(["postId": .integer(9007199254741001)])])])
        let first = Task { await store.observe(app, "feed", ["pagerId": .string("first"), "sort": .string("LAST_REPLY")]) }
        try await eventually { transport.hasStream("feed") }
        transport.emit("feed", .object(["items": rows, "pagerId": .string("first"), "refresh": .object(["status": .string("NotLoading")])]))
        try await eventually { store.value["items"] == rows }
        first.cancel(); await first.value; transport.finish("feed")
        let second = Task { await store.observe(app, "feed", ["pagerId": .string("replacement"), "sort": .string("LAST_REPLY")]) }
        try await eventually { transport.hasStream("feed") }
        #expect(store.value["items"] == rows, "A new pager handle is not a new feed identity")
        transport.emit("feed", .object(["items": .array([]), "pagerId": .string("replacement"), "refresh": .object(["status": .string("Loading")])]))
        try await eventually { store.value.nativeString("pagerId") == "replacement" }
        #expect(store.isReplacingPagingWindow)
        #expect(store.value["items"] == rows, "Empty loading window must not erase the previous loaded window")
        transport.emit("feed", .object(["items": .array([]), "pagerId": .string("replacement"), "refresh": .object(["status": .string("NotLoading")])]))
        try await eventually { store.value["items"] == .array([]) }
        second.cancel(); await second.value
    }

    @Test func changingQueryCannotDisplayPreviousQueryRowsWhileLoading() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let first = Task { await store.load(app, "search.users", ["query": .string("old")]) }
        try await eventually { transport.hasRequest("search.users") }
        transport.resolve("search.users", .success(.array([.string("old result")])))
        await first.value
        let second = Task { await store.load(app, "search.users", ["query": .string("new")]) }
        try await eventually { transport.hasRequest("search.users") }
        #expect(store.value == .null)
        #expect(store.isLoading)
        transport.resolve("search.users", .success(.array([])))
        await second.value
    }

    @Test func freshOneShotReturnCoalescesAndStaleRefreshKeepsRowsOnFailure() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        let first = Task { await store.loadIfStale(app, "categories") }
        try await eventually { transport.hasRequest("categories") }
        let joined = Task { await store.loadIfStale(app, "categories") }
        await Task.yield()
        #expect(transport.arguments(for: "categories").count == 1)
        transport.resolve("categories", .success(.array([])))
        await first.value; await joined.value
        await store.loadIfStale(app, "categories")
        #expect(transport.arguments(for: "categories").count == 1)
        uptime = 161
        let refresh = Task { await store.loadIfStale(app, "categories") }
        try await eventually { transport.arguments(for: "categories").count == 2 }
        #expect(store.value == .array([]))
        #expect(!store.isLoading)
        #expect(store.isRefreshing)
        transport.resolve("categories", .failure(NativeFailure(code: "NETWORK", message: "offline")))
        await refresh.value
        #expect(store.value == .array([]))
        #expect(store.failure?.code == "NETWORK")
        #expect(!store.isRefreshing)
        let retry = Task { await store.loadIfStale(app, "categories") }
        try await eventually { transport.arguments(for: "categories").count == 3 }
        transport.resolve("categories", .success(.array([.string("new") ])))
        await retry.value
        #expect(store.value == .array([.string("new")]))
    }

    @Test(arguments: [false, true]) func freshObservationReturnDoesNotResubscribeUntilInvalidatedByMutation(mutationFails: Bool) async throws {
        let probe = RetentionProbe()
        let app = NativeAppModel(transport: probe.transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        let first = Task { await store.observeCached(app, "notifications.list") }
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply("{\"ok\":true,\"data\":[\"cached\"]}")
        try await eventually { store.value == .array([.string("cached")]) }
        first.cancel(); await first.value
        try await eventually { probe.observationCancels == 1 }
        uptime = 120
        var returned = false
        let second = Task { returned = true; await store.observeCached(app, "notifications.list") }
        try await eventually { returned }
        #expect(probe.observations.count == 1)
        #expect(!store.isLoading)
        let mutation = Task { try await app.request("notifications.readAll", ["category": .string("REPLIES")]) }
        try await eventually { probe.requests.count == 1 }
        probe.requests[0].reply(mutationFails ? "{\"ok\":false,\"error\":{\"code\":\"NETWORK\",\"message\":\"offline\"}}" : "{\"ok\":true,\"data\":null}")
        let result = await mutation.result
        switch result {
        case .success: #expect(!mutationFails)
        case .failure: #expect(mutationFails)
        }
        try await eventually { probe.observations.count == 2 }
        #expect(store.value == .array([.string("cached")]))
        #expect(!store.isLoading)
        #expect(store.isRefreshing)
        probe.observations[1].reply("{\"ok\":false,\"error\":{\"code\":\"NETWORK\",\"message\":\"offline\"}}")
        await second.value
        #expect(store.value == .array([.string("cached")]))
        #expect(store.failure?.code == "NETWORK")
        let retry = Task { await store.observeCached(app, "notifications.list") }
        try await eventually { probe.observations.count == 3 }
        probe.observations[2].reply("{\"ok\":true,\"data\":[]}")
        try await eventually { store.value == .array([]) }
        retry.cancel(); await retry.value
        var entered = false
        let freshEmpty = Task { entered = true; await store.observeCached(app, "notifications.list") }
        try await eventually { entered }
        freshEmpty.cancel(); await freshEmpty.value
        #expect(probe.observations.count == 3, "A loaded empty list is a cache hit")
        #expect(store.value == .array([]))
    }

    @Test func cancelledRefreshDoesNotRenewFreshnessAndCanRetry() async throws {
        let probe = RetentionProbe()
        let app = NativeAppModel(transport: probe.transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        let first = Task { await store.loadIfStale(app, "categories") }
        try await eventually { probe.requests.count == 1 }
        probe.requests[0].reply("{\"ok\":true,\"data\":[\"old\"]}")
        await first.value
        uptime = 161
        let cancelled = Task { await store.loadIfStale(app, "categories") }
        try await eventually { probe.requests.count == 2 }
        cancelled.cancel(); await cancelled.value
        #expect(store.value == .array([.string("old")]))
        #expect(!store.isLoading && !store.isRefreshing)
        let retry = Task { await store.loadIfStale(app, "categories") }
        try await eventually { probe.requests.count == 3 }
        probe.requests[1].reply("{\"ok\":true,\"data\":[\"late\"]}")
        #expect(store.value == .array([.string("old")]))
        probe.requests[2].reply("{\"ok\":true,\"data\":[\"new\"]}")
        await retry.value
        #expect(store.value == .array([.string("new")]))
    }

    @Test(arguments: [false, true]) func revokedCachedObservationCannotPublishLateRows(siteChange: Bool) async throws {
        let probe = RetentionProbe()
        let app = NativeAppModel(transport: probe.transport)
        try app.applySite(testSite)
        app.session = .object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)])
        let store = NativeStore()
        let first = Task { await store.observeCached(app, "notifications.list") }
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply("{\"ok\":true,\"data\":[\"private A\"]}")
        try await eventually { store.value == .array([.string("private A")]) }
        first.cancel(); await first.value
        let waiting = Task { await store.observeCached(app, "notifications.list") }
        await Task.yield()
        if siteChange {
            var changed = testSite.object!
            changed["current"] = .string("NODESEEK")
            try app.applySite(.object(changed))
        } else {
            app.session = .object(["identityEpoch": .string("B"), "isSignedIn": .bool(false), "generation": .integer(2)])
        }
        #expect(store.value == .null)
        await waiting.value
        probe.observations[0].reply("{\"ok\":true,\"data\":[\"late A\"]}")
        #expect(store.value == .null)
        let replacement = Task { await store.observeCached(app, "notifications.list") }
        try await eventually { probe.observations.count == 2 }
        #expect(store.isLoading)
        #expect(store.value == .null)
        replacement.cancel(); await replacement.value
    }

    @Test func staleObservationReturnReconnectsImmediatelyWithRowsIntact() async throws {
        let probe = RetentionProbe()
        let app = NativeAppModel(transport: probe.transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        let first = Task { await store.observeCached(app, "messages.list") }
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply("{\"ok\":true,\"data\":[\"row40\"]}")
        try await eventually { store.value == .array([.string("row40")]) }
        first.cancel(); await first.value
        uptime = 161
        let returned = Task { await store.observeCached(app, "messages.list") }
        try await eventually { probe.observations.count == 2 }
        #expect(store.value == .array([.string("row40")]))
        #expect(!store.isLoading && store.isRefreshing)
        returned.cancel(); await returned.value
        #expect(probe.observations.count == 2)
    }

    @Test func observationReturnKeepsLoadedRowsWithoutInitialLoading() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let rows = JSONValue.array([.object(["id": .string("row-40")])])
        let first = Task { await store.observe(app, "notifications.list") }
        try await eventually { transport.hasStream("notifications.list") }
        #expect(store.isLoading)
        transport.emit("notifications.list", rows)
        try await eventually { store.value == rows }
        first.cancel(); await first.value
        #expect(store.value == rows)
        transport.finish("notifications.list")
        let returned = Task { await store.observe(app, "notifications.list") }
        try await eventually { transport.hasStream("notifications.list") }
        #expect(store.value == rows)
        #expect(!store.isLoading, "Returning to loaded notifications must not restart initial loading")
        returned.cancel(); await returned.value
    }
}
