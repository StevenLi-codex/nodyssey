import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@MainActor private final class RetainedStreamProbe {
    struct Call {
        let name: String
        let arguments: String
        let reply: @Sendable (String) -> Void
    }
    var calls: [Call] = []
    var cancellations = 0
    lazy var transport = CallbackNativeTransport(request: { _, _, _ in
        fatalError("No one-shot request expected")
    }, observe: { [weak self] name, args, reply in
        self?.calls.append(Call(name: name, arguments: args, reply: reply))
        return NativeCancellation { [weak self] in Task { @MainActor in self?.cancellations += 1 } }
    })
}

@Suite @MainActor struct RetainedObservationTests {
    @Test func tabTaskCancellationKeepsOriginalPagerAndContinuesUpdates() async throws {
        let probe = RetainedStreamProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore()
        let args: [String: JSONValue] = ["pagerId": .string("original"), "sort": .string("LAST_REPLY")]
        let appearance = Task { store.observeRetained(app, "feed", args) }
        #expect(await appearance.value)
        try await eventually { probe.calls.count == 1 }
        probe.calls[0].reply(#"{"ok":true,"data":{"pagerId":"original","items":[{"summary":{"postId":42},"page":4}]}}"#)
        try await eventually { store.value["items"]?.array?.count == 1 }
        appearance.cancel()
        for _ in 0..<20 {
            #expect(!store.observeRetained(app, "feed", args))
        }
        #expect(probe.calls.count == 1)
        #expect(probe.cancellations == 0)
        #expect(!store.isReplacingPagingWindow)
        probe.calls[0].reply(#"{"ok":true,"data":{"pagerId":"original","items":[{"summary":{"postId":42,"replyCount":2},"page":4}]}}"#)
        try await eventually { store.value["items"]?.array?.first?["summary"]?["replyCount"]?.int == 2 }
        store.cancel()
        try await eventually { probe.cancellations == 1 }
    }

    @Test func initialLoadingIsImmediateAndEmptyResponseSurvivesReturn() async throws {
        let probe = RetainedStreamProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore()
        #expect(!store.hasValue)
        #expect(store.observeRetained(app, "notifications.list"))
        #expect(store.isLoading, "No scheduling gap before the first loading presentation")
        try await eventually { probe.calls.count == 1 }
        probe.calls[0].reply(#"{"ok":true,"data":[]}"#)
        try await eventually { store.hasValue }
        #expect(!store.isLoading)
        #expect(!store.observeRetained(app, "notifications.list"))
        #expect(store.value == .array([]))
        store.cancel()
    }

    @Test func revocationErasesRowsAndFencesQueuedOldCompletion() async throws {
        let probe = RetainedStreamProbe()
        let app = NativeAppModel(transport: probe.transport)
        app.session = .object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)])
        let store = NativeStore()
        store.observeRetained(app, "notifications.list")
        try await eventually { probe.calls.count == 1 }
        probe.calls[0].reply(#"{"ok":true,"data":["private A"]}"#)
        try await eventually { store.hasValue }
        app.session = .object(["identityEpoch": .string("B"), "isSignedIn": .bool(true), "generation": .integer(2)])
        #expect(store.value == .null)
        #expect(!store.hasValue)
        store.observeRetained(app, "notifications.list")
        try await eventually { probe.calls.count == 2 }
        probe.calls[0].reply(#"{"ok":true,"data":["late A"]}"#)
        probe.calls[1].reply(#"{"ok":true,"data":["B"]}"#)
        try await eventually { store.value == .array([.string("B")]) }
        #expect(probe.cancellations == 1)
        store.cancel()
    }

    @Test func pagingIdleAndLoadingAreNotLoadedEmptyResults() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        store.observeRetained(app, "feed", ["pagerId": .string("p")])
        try await eventually { transport.hasStream("feed") }
        for status in ["Idle", "Loading"] {
            let value: JSONValue = .object(["pagerId": .string("p"), "items": .array([]), "refresh": .object(["status": .string(status)])])
            transport.emit("feed", value)
            try await eventually { store.value == value }
            #expect(store.isLoading, "A presenter shell must not turn the loading screen into an empty List")
            #expect(!store.hasValue)
        }
        transport.emit("feed", .object(["pagerId": .string("p"), "items": .array([]), "refresh": .object(["status": .string("NotLoading")])]))
        try await eventually { store.value["refresh"]?["status"] == .string("NotLoading") }
        #expect(store.hasValue && !store.isLoading)
        transport.emit("feed", .object(["pagerId": .string("p"), "items": .array([]), "refresh": .object(["status": .string("Loading")])]))
        try await eventually { store.value["refresh"]?["status"] == .string("Loading") }
        #expect(store.hasValue && !store.isLoading, "Refreshing a loaded empty feed must retain its empty result")
        store.cancel()
    }

    @Test func cancelledAppearanceCannotStartRetainedWork() async throws {
        let probe = RetainedStreamProbe()
        let app = NativeAppModel(transport: probe.transport)
        let store = NativeStore()
        let appearance = Task { store.observeRetained(app, "notifications.list") }
        appearance.cancel() // MainActor has not yielded: this task has not started.
        #expect(!(await appearance.value))
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.calls.isEmpty)
        #expect(!store.isLoading)
        store.cancel()
    }

    @Test func ownerReleaseCancelsWithoutSelfRetainCycle() async throws {
        let probe = RetainedStreamProbe()
        let app = NativeAppModel(transport: probe.transport)
        var store: NativeStore? = NativeStore()
        weak var weakStore = store
        store?.observeRetained(app, "messages.list")
        try await eventually { probe.calls.count == 1 }
        store = nil
        #expect(weakStore == nil)
        try await eventually { probe.cancellations == 1 }
    }
}
