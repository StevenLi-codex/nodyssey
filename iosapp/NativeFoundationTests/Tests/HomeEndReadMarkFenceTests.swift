import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

/// The ordinary-Back paint may only be authorized by a mark whose evidence no
/// other read-mark producer can forge. These lock the producer fence and the
/// editor-transport passthrough; the mounted geometry is covered separately.
@Suite @MainActor struct HomeEndReadMarkFenceTests {
    @Test func everyReadMarkProducerIsAConflict() {
        for operation in ["thread.markRead", "editor.comment.publish",
                          "history.restore", "history.remove", "history.clear"] {
            #expect(HomeEndReadMarkPolicy.conflicts(operation), "\(operation) writes the read-mark table")
        }
    }

    @Test func ordinaryEditorAndPagingTrafficIsNotAConflict() {
        for operation in ["editor.draft.save", "editor.draft.get", "editor.preview",
                          "editor.image.upload", "paging.access", "thread.position.get"] {
            #expect(!HomeEndReadMarkPolicy.conflicts(operation), "\(operation) must stay transparent")
        }
    }

    @Test func observedTransportPassesDraftsThroughAndCountsPublish() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let guarded = app.transport

        let draft = Task { try await guarded.request("editor.draft.save", ["body": .string("draft")]) }
        try await eventually { transport.hasRequest("editor.draft.save") }
        #expect(app.paintObservedInFlight == 0, "a draft save is not a read-mark producer")
        #expect(transport.arguments(for: "editor.draft.save").count == 1)
        transport.resolve("editor.draft.save", .success(.null))
        _ = try await draft.value

        let publish = Task { try await guarded.request("editor.comment.publish", ["body": .string("reply")]) }
        try await eventually { transport.hasRequest("editor.comment.publish") }
        #expect(app.paintObservedInFlight == 1, "an in-flight publish must block arming")
        transport.resolve("editor.comment.publish", .success(.null))
        _ = try await publish.value
        #expect(app.paintObservedInFlight == 0)
        #expect(transport.arguments(for: "editor.comment.publish").count == 1, "payload is forwarded unchanged")
    }

    @Test func failedPublishStillReleasesTheInFlightCount() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let guarded = app.transport
        let publish = Task { try await guarded.request("editor.comment.publish", [:]) }
        try await eventually { transport.hasRequest("editor.comment.publish") }
        transport.resolve("editor.comment.publish", .failure(NativeFailure(code: "IO", message: "refused")))
        do {
            _ = try await publish.value
            Issue.record("a failed publish must not resume as success")
        } catch { }
        #expect(app.paintObservedInFlight == 0)
    }
}
