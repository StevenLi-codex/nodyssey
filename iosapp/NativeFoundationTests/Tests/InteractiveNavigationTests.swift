import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct InteractiveNavigationTests {
    @Test func releasedSwipeDoesNotCloseRealReplyUntilMatchingVisualCommit() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("UserSpace", ["uid": .integer(9)])
        let parent = try #require(app.homePath.last)
        app.open("PostDetail", ["postId": .integer(4)])
        let detail = try #require(app.homePath.last)
        let reply = EditorReplyLifetime()
        app.registerDismissal(destinationID: detail.id, close: { await reply.prepareDeparture() },
            revoke: { reply.invalidate() }, terminate: { reply.terminateAfterPrepared() },
            validate: { reply.isDeparturePreparationValid })
        let load = Task { await reply.open(postID: 4, transport: transport, generation: app.generation) }
        try await eventually { transport.hasRequest("draft.comment.get") }
        transport.resolve("draft.comment.get", .success(.null))
        await load.value
        let editor = try #require(reply.model)
        editor.session.changeBody(EditorBuffer(text: "retain until the previous screen settles"))

        let cancelled = try #require(app.beginInteractivePop(stack: .home, from: detail.id))
        app.cancelInteractivePop(cancelled)
        #expect(transport.arguments(for: "draft.comment.save").isEmpty)
        #expect(app.homePath == [parent, detail] && !editor.isClosed)

        let lease = try #require(app.beginInteractivePop(stack: .home, from: detail.id))
        #expect(app.canResumeInteractivePop(lease))
        let release = Task { await app.prepareInteractivePop(lease) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        #expect(!app.canResumeInteractivePop(lease), "A held draft save cannot be interrupted by a second release")
        await app.dismissDestination(detail.id) // Competing explicit back must not close it.
        #expect(app.homePath == [parent, detail] && !editor.isClosed)
        transport.resolve("draft.comment.save", .success(.null))
        #expect(await release.value)
        #expect(app.canResumeInteractivePop(lease), "A prepared visual settle can be re-grabbed on the same lease")
        #expect(app.homePath == [parent, detail] && !editor.isClosed,
                "A successful draft flush is not a matching visual commit")
        #expect(!app.commitInteractivePop(lease, visible: detail.id))
        #expect(app.homePath == [parent, detail] && !editor.isClosed)
        #expect(app.commitInteractivePop(lease, visible: parent.id))
        #expect(!app.commitInteractivePop(lease, visible: parent.id))
        #expect(app.homePath == [parent] && editor.isClosed)
        #expect(transport.arguments(for: "draft.comment.save").count == 1)
        #expect(transport.arguments(for: "editor.comment.publish").isEmpty)
    }

    @Test func refusedSaveKeepsReplyAndCannotBeReusedByAnotherSwipe() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("PostDetail", ["postId": .integer(4)])
        let detail = try #require(app.homePath.last)
        #expect(app.beginInteractivePop(stack: .home, from: detail.id) == nil)
        let reply = EditorReplyLifetime()
        app.registerDismissal(destinationID: detail.id, close: { await reply.prepareDeparture() },
            revoke: { reply.invalidate() }, terminate: { reply.terminateAfterPrepared() },
            validate: { reply.isDeparturePreparationValid })
        let load = Task { await reply.open(postID: 4, transport: transport, generation: app.generation) }
        try await eventually { transport.hasRequest("draft.comment.get") }
        transport.resolve("draft.comment.get", .success(.null))
        await load.value
        let editor = try #require(reply.model)
        editor.session.changeBody(EditorBuffer(text: "save refused"))
        let pop = try #require(app.beginInteractivePop(stack: .home, from: detail.id))
        let save = Task { await app.prepareInteractivePop(pop) }
        try await eventually { transport.hasRequest("draft.comment.save") }
        transport.resolve("draft.comment.save", .failure(NativeFailure(code: "NETWORK", message: "fixture")))
        #expect(await save.value == false)
        #expect(!app.canFinishInteractivePop(pop))
        #expect(!app.canResumeInteractivePop(pop))
        #expect(app.beginInteractivePop(stack: .home, from: detail.id) == nil)
        app.cancelInteractivePop(pop)
        #expect(app.homePath == [detail] && !editor.isClosed && reply.visible)
        #expect(editor.session.body.text == "save refused")
        let next = try #require(app.beginInteractivePop(stack: .home, from: detail.id))
        #expect(!app.commitInteractivePop(pop, visible: nil))
        app.cancelInteractivePop(next)
    }

    @Test func editAfterPreparationDoesNotCommitAndPathRoundTripInvalidatesLease() async throws {
        let app = NativeAppModel(transport: ControlledTransport())
        app.open("PostDetail", ["postId": .integer(4)])
        let id = try #require(app.homePath.last?.id)
        var valid = true
        var terminations = 0
        app.registerDismissal(destinationID: id, close: { true }, revoke: {},
            terminate: { terminations += 1 }, validate: { valid })
        let pop = try #require(app.beginInteractivePop(stack: .home, from: id))
        #expect(await app.prepareInteractivePop(pop))
        valid = false
        #expect(!app.canResumeInteractivePop(pop))
        #expect(!app.commitInteractivePop(pop, visible: nil))
        app.cancelInteractivePop(pop)
        valid = true
        let next = try #require(app.beginInteractivePop(stack: .home, from: id))
        app.selectedTab = .profile
        app.selectedTab = .home
        #expect(await app.prepareInteractivePop(next) == false)
        app.cancelInteractivePop(next)
        #expect(app.homePath.last?.id == id && terminations == 0)
    }

    @Test func accountRevocationDuringSaveNeverTerminatesReplacement() async throws {
        let app = NativeAppModel(transport: ControlledTransport())
        app.session = boundarySession()
        let root = UUID()
        #expect(app.beginInteractivePop(stack: .home, from: root) == nil)
        app.open("Stardust")
        let from = try #require(app.homePath.last?.id)
        var pending: CheckedContinuation<Bool, Never>?
        var revoked = 0
        var terminated = 0
        app.registerDismissal(destinationID: from, close: { await withCheckedContinuation { pending = $0 } },
            revoke: { revoked += 1 }, terminate: { terminated += 1 })
        let old = try #require(app.beginInteractivePop(stack: .home, from: from))
        let release = Task { await app.prepareInteractivePop(old) }
        try await eventually { pending != nil }
        app.session = boundarySession(.string("process-B"))
        app.open("UserSpace")
        let replacement = try #require(app.homePath.last?.id)
        pending?.resume(returning: true)
        #expect(await release.value == false)
        #expect(!app.commitInteractivePop(old, visible: nil))
        #expect(app.homePath.last?.id == replacement && revoked == 1 && terminated == 0)
    }
}
