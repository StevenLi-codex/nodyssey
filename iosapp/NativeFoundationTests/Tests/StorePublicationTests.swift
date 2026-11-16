import Foundation
import Combine
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct StorePublicationTests {
    @Test func unchangedTransportValueDoesNotRepublishRows() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let task = Task { await store.observe(app, "notifications.list") }
        defer { task.cancel() }
        try await eventually { transport.hasStream("notifications.list") }
        let rows = JSONValue.array([.object(["id": .string("same"), "isUnread": .bool(true)])])
        transport.emit("notifications.list", rows)
        try await eventually { store.value == rows }
        var publications: [JSONValue] = []
        let subscription = store.$value.dropFirst().sink { publications.append($0) }
        transport.emit("notifications.list", rows)
        // Ordered barrier: a changed emission proves the equal one was consumed first.
        let changed = JSONValue.array([.object(["id": .string("same"), "isUnread": .bool(false)])])
        transport.emit("notifications.list", changed)
        try await eventually { store.value == changed }
        #expect(publications == [changed], "Equal transport values must not invalidate the entire List")
        task.cancel(); await task.value
        #expect(publications == [changed], "Cancellation is not a content change")
        withExtendedLifetime(subscription) {}
    }
}
