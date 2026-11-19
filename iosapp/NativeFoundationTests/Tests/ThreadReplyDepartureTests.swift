import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

/// Real app navigation + real thread-owned editor; transport alone is controlled.
@Suite @MainActor struct ThreadReplyDepartureTests {
    @Test func swipeFallbackAndSystemPopShareDraftGateAndNeverPopParentTwice() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("UserSpace", ["uid": .integer(9)])
        let parent = try #require(app.homePath.last)
        app.open("PostDetail", ["postId": .integer(4)])
        let id = try #require(app.homePath.last?.id)
        let owner = EditorReplyLifetime()
        app.registerDismissal(destinationID: id, close: { await owner.prepareDeparture() },
            revoke: { owner.invalidate() }, terminate: { owner.terminateAfterPrepared() },
            validate: { owner.isDeparturePreparationValid })
        let open = Task { await owner.open(postID: 4, transport: transport, generation: app.generation) }
        try await eventually { transport.hasRequest("draft.comment.get") }
        transport.resolve("draft.comment.get", .success(.null))
        await open.value
        let model = try #require(owner.model)
        model.session.changeBody(EditorBuffer(text: "keep this unsent reply"))
        let failed = Task { await app.dismissDestination(id) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        await app.updatePath([parent], for: .home)
        await app.dismissDestination(id)
        #expect(transport.arguments(for: "draft.comment.save").count == 1)
        transport.resolve("draft.comment.save", .failure(NativeFailure(code: "NETWORK", message: "fixture")))
        await failed.value
        #expect(app.homePath.last?.id == id && !model.isClosed)
        #expect(model.session.body.text == "keep this unsent reply")
        let success = Task { await app.dismissDestination(id) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        transport.resolve("draft.comment.save", .success(.null))
        await success.value
        await app.dismissDestination(id) // A delayed fallback cannot dismiss the parent.
        #expect(app.homePath == [parent])
        #expect(model.isClosed)
        #expect(transport.arguments(for: "editor.comment.publish").isEmpty)
    }

    @Test func threadPopWaitsForReplySaveAndRefusedPopRetainsLiveSheet() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("PostDetail", ["postId": .integer(4)])
        let id = try #require(app.homePath.last?.id)
        let owner = EditorReplyLifetime()
        app.registerDismissal(destinationID: id, close: { await owner.prepareDeparture() }, revoke: { owner.invalidate() }, terminate: { owner.terminateAfterPrepared() }, validate: { owner.isDeparturePreparationValid })
        let open = Task { await owner.open(postID: 4, transport: transport, generation: app.generation) }
        try await eventually { transport.hasRequest("draft.comment.get") }
        transport.resolve("draft.comment.get", .success(.null))
        await open.value
        let model = try #require(owner.model)
        model.session.changeBody(EditorBuffer(text: "draft before pop"))
        let failed = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        #expect(app.homePath.last?.id == id && !model.isClosed)
        transport.resolve("draft.comment.save", .failure(NativeFailure(code: "NETWORK", message: "fixture")))
        await failed.value
        #expect(app.homePath.last?.id == id && owner.visible && !model.isClosed)
        #expect(model.session.body.text == "draft before pop")
        let success = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        transport.resolve("draft.comment.save", .success(.null))
        await success.value
        #expect(app.homePath.isEmpty && model.isClosed && !owner.visible)
        #expect(transport.arguments(for: "editor.comment.publish").isEmpty)
    }

    @Test func threadIdentityRevocationDuringHideNeverReopensOrSavesUnderReplacement() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        app.open("PostDetail", ["postId": .integer(4)])
        let id = try #require(app.homePath.last?.id)
        let owner = EditorReplyLifetime()
        app.registerDismissal(destinationID: id, close: { await owner.prepareDeparture() }, revoke: { owner.invalidate() }, terminate: { owner.terminateAfterPrepared() }, validate: { owner.isDeparturePreparationValid })
        let open = Task { await owner.open(postID: 4, transport: transport, generation: app.generation) }
        try await eventually { transport.hasRequest("draft.comment.get") }
        transport.resolve("draft.comment.get", .success(.null))
        await open.value
        let model = try #require(owner.model)
        model.session.changeBody(EditorBuffer(text: "old identity"))
        let hide = Task { await owner.hide() }
        try await eventually { transport.hasRequest("draft.comment.save") }
        app.session = boundarySession(.string("process-B"))
        transport.resolve("draft.comment.save", .success(.null))
        #expect(await hide.value == false)
        #expect(app.homePath.isEmpty && model.isClosed && !owner.visible)
        #expect(model.session.body.text.isEmpty)
        #expect(transport.arguments(for: "draft.comment.save").count == 1)
    }
}
