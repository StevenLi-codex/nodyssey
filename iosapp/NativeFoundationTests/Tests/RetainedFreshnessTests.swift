import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@MainActor private final class FreshnessProbe {
    struct Call { let name: String; let reply: @Sendable (String) -> Void }
    var observations: [Call] = []
    var requests: [Call] = []
    var observationCancels = 0
    var requestCancels = 0
    lazy var transport = CallbackNativeTransport(request: { [weak self] name, _, reply in
        self?.requests.append(Call(name: name, reply: reply))
        return NativeCancellation { [weak self] in Task { @MainActor in self?.requestCancels += 1 } }
    }, observe: { [weak self] name, _, reply in
        self?.observations.append(Call(name: name, reply: reply))
        return NativeCancellation { [weak self] in Task { @MainActor in self?.observationCancels += 1 } }
    })
}

@Suite @MainActor struct RetainedFreshnessTests {
    @Test(arguments: ["notifications.list", "messages.list"])
    func staleReturnRefreshesWithoutReplacingSubscriptionAndOnlyDataRenewsTTL(name: String) async throws {
        let probe = FreshnessProbe()
        let app = NativeAppModel(transport: probe.transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        store.observeRetained(app, name)
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply(#"{"ok":true,"data":["old"]}"#)
        try await eventually { store.hasValue }
        uptime = 159
        for _ in 0..<20 { store.observeRetained(app, name) }
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.requests.isEmpty)
        uptime = 160
        store.observeRetained(app, name)
        try await eventually { probe.requests.count == 1 }
        #expect(probe.requests[0].name == (name == "messages.list" ? "messages.refresh" : "notifications.refresh"))
        #expect(store.value == .array([.string("old")]) && !store.isLoading)
        for _ in 0..<20 { store.observeRetained(app, name) }
        #expect(probe.requests.count == 1 && probe.observations.count == 1)
        #expect(probe.observationCancels == 0)
        probe.requests[0].reply(#"{"ok":true,"data":null}"#)
        for _ in 0..<100 { await Task.yield() }
        store.observeRetained(app, name)
        #expect(probe.requests.count == 1, "An acknowledgement is not refreshed list data; coalesce until the revision arrives")
        probe.observations[0].reply(#"{"ok":true,"data":["new"]}"#)
        try await eventually { store.value == .array([.string("new")]) }
        uptime = 219
        store.observeRetained(app, name)
        #expect(probe.requests.count == 1)
        uptime = 220
        store.observeRetained(app, name)
        try await eventually { probe.requests.count == 2 }
        store.cancel()
    }

    @Test func refreshFailureKeepsRowsAndAllowsRetryWithoutResubscription() async throws {
        let probe = FreshnessProbe()
        let app = NativeAppModel(transport: probe.transport)
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        store.observeRetained(app, "notifications.list")
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply(#"{"ok":true,"data":[]}"#)
        try await eventually { store.hasValue }
        uptime = 160
        store.observeRetained(app, "notifications.list")
        try await eventually { probe.requests.count == 1 }
        probe.requests[0].reply(#"{"ok":false,"error":{"code":"NETWORK","message":"offline"}}"#)
        try await eventually { store.failure?.code == "NETWORK" }
        #expect(store.value == .array([]) && !store.isLoading)
        store.observeRetained(app, "notifications.list")
        try await eventually { probe.requests.count == 2 }
        #expect(probe.observations.count == 1 && probe.observationCancels == 0)
        store.cancel()
    }

    @Test func identityRevocationCancelsRefreshAndRejectsOldCallbacks() async throws {
        let probe = FreshnessProbe()
        let app = NativeAppModel(transport: probe.transport)
        app.session = .object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)])
        var uptime: TimeInterval = 100
        let store = NativeStore(now: { uptime })
        store.observeRetained(app, "messages.list")
        try await eventually { probe.observations.count == 1 }
        probe.observations[0].reply(#"{"ok":true,"data":["A"]}"#)
        try await eventually { store.hasValue }
        uptime = 160
        store.observeRetained(app, "messages.list")
        try await eventually { probe.requests.count == 1 }
        app.session = .object(["identityEpoch": .string("B"), "isSignedIn": .bool(true), "generation": .integer(2)])
        try await eventually { probe.requestCancels == 1 }
        probe.requests[0].reply(#"{"ok":true,"data":null}"#)
        probe.observations[0].reply(#"{"ok":true,"data":["late A"]}"#)
        for _ in 0..<30 { await Task.yield() }
        #expect(store.value == .null && !store.hasValue)
        store.observeRetained(app, "messages.list")
        try await eventually { probe.observations.count == 2 }
        store.cancel()
    }
}
