import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct IndependentDepartureReviewTests {
    @Test func ownerCapturedBeforeSchedulingCannotPopReplacementIdentityOrNewRevision() async throws {
        let app = NativeAppModel(transport: IdleTransport())
        app.session = boundarySession()
        app.open("Help")
        let oldIdentity = app.capturePathUpdateOwner()
        app.session = boundarySession(.string("process-B"))
        app.open("Settings")
        let replacement = app.homePath
        await app.updatePath([], for: .home, owner: oldIdentity)
        #expect(app.homePath == replacement)
        let oldRevision = app.capturePathUpdateOwner()
        app.open("Help")
        let newer = app.homePath
        await app.updatePath(replacement, for: .home, owner: oldRevision)
        #expect(app.homePath == newer)
        await app.updatePath(replacement, for: .home, owner: app.capturePathUpdateOwner())
        #expect(app.homePath == replacement)
    }

    @Test(arguments: [false, true]) func earlierOwnerInputMustBeRevalidatedAfterLaterOwnerSave(attachmentArrives: Bool) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("PostComposer")
        let postID = try #require(app.homePath.last?.id)
        let post = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let postOwner = NativeEditorRouteLifetime(model: post)
        postOwner.register(app: app, destinationID: postID)
        let load = Task { await post.load() }
        try await eventually { transport.hasRequest("draft.post.get") }
        transport.resolve("draft.post.get", .success(.null))
        await load.value
        post.session.changeBody(EditorBuffer(text: "post draft"))
        app.selectedTab = .notifications
        app.open("MessageThread", ["uid": .integer(43)])
        let messageID = try #require(app.notificationsPath.last?.id)
        let message = EditorViewModel(mode: .message(uid: 43), transport: IdleTransport(), arguments: [:])
        let messageOwner = NativeEditorRouteLifetime(model: message)
        messageOwner.register(app: app, destinationID: messageID)
        await message.appear(generation: app.generation)
        message.session.changeBody(EditorBuffer(text: "initial message"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        message.addFile(file)
        let reset = Task { await app.resetNavigationAwaitingDeparture() }
        try await eventually { transport.hasRequest("draft.post.save") }
        let lateFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: lateFile) }
        if attachmentArrives {
            try Data("late picker fixture".utf8).write(to: lateFile)
            message.addFile(lateFile)
        } else {
            message.session.changeBody(EditorBuffer(text: "new message while post saves"))
        }
        transport.resolve("draft.post.save", .success(.null))
        await reset.value
        #expect(app.homePath.last?.id == postID)
        #expect(app.notificationsPath.last?.id == messageID)
        #expect(!post.isClosed)
        #expect(!message.isClosed)
        #expect(message.session.body.text == (attachmentArrives ? "initial message" : "new message while post saves"))
        #expect(message.attachments.count == (attachmentArrives ? 2 : 1))
        #expect(FileManager.default.fileExists(atPath: file.path))
        post.invalidate()
        message.invalidate()
    }

    @Test func queuedRootPathBindingPopMustNotReinstallOldIdentityDestinations() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        let initialBoundary = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot("READY", confirmation: false)))
        await initialBoundary.value
        #expect(app.isPrivateReady)
        app.open("PostComposer", ["reply": .bool(true), "postId": .integer(7), "replyToText": .string("A private quoted text")])
        let editor = try #require(app.homePath.last)
        let model = EditorViewModel(mode: .reply(postID: 7), transport: transport, arguments: editor.arguments)
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: editor.id)
        app.open("Help")
        let value = Array(app.homePath.prefix(1))
        // Controlled executor delay for NativeRootView's unstructured binding Task.
        var release: CheckedContinuation<Void, Never>?
        let pendingBindingSet = Task {
            await withCheckedContinuation { release = $0 }
            await app.updatePath(value, for: .home)
        }
        try await eventually { release != nil }
        app.session = boundarySession(.string("process-B"))
        #expect(app.homePath.isEmpty)
        #expect(model.isClosed)
        let boundary = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot("READY", epoch: "process-B", confirmation: false)))
        await boundary.value
        #expect(app.isPrivateReady)
        release?.resume()
        await pendingBindingSet.value
        #expect(app.homePath.isEmpty)
        #expect(!app.homePath.contains(where: { $0.arguments["replyToText"]?.string == "A private quoted text" }))
    }

    @Test func navigationChangedDuringSaveMustNotLeaveClosedEditorOnRetainedRoute() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.open("PostComposer")
        let id = try #require(app.homePath.last?.id)
        let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: id)
        let load = Task { await model.load() }
        try await eventually { transport.hasRequest("draft.post.get") }
        transport.resolve("draft.post.get", .success(.null))
        await load.value
        model.session.changeBody(EditorBuffer(text: "retained draft"))
        let close = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.post.save") }
        app.selectedTab = .profile
        app.open("Help")
        transport.resolve("draft.post.save", .success(.null))
        await close.value
        #expect(app.homePath.last?.id == id)
        #expect(app.profilePath.last?.route == "Help")
        #expect(!model.isClosed)
        #expect(model.session.body.text == "retained draft")
        model.invalidate()
    }

    @Test func resetRefusalMustNotDestroyOtherEditorsWhoseRoutesRemain() async throws {
        let app = NativeAppModel(transport: IdleTransport())
        app.open("PostComposer")
        let postID = try #require(app.homePath.last?.id)
        let post = EditorViewModel(mode: .post, transport: IdleTransport(), arguments: [:])
        let postOwner = NativeEditorRouteLifetime(model: post)
        postOwner.register(app: app, destinationID: postID)
        // Real close refuses until the draft is loaded.
        post.session.changeBody(EditorBuffer(text: "unloaded post"))
        app.selectedTab = .notifications
        app.open("MessageThread", ["uid": .integer(42)])
        let messageID = try #require(app.notificationsPath.last?.id)
        let message = EditorViewModel(mode: .message(uid: 42), transport: IdleTransport(), arguments: [:])
        let messageOwner = NativeEditorRouteLifetime(model: message)
        messageOwner.register(app: app, destinationID: messageID)
        await message.appear(generation: app.generation)
        message.session.changeBody(EditorBuffer(text: "message still on screen"))
        await app.resetNavigationAwaitingDeparture()
        #expect(app.homePath.last?.id == postID)
        #expect(post.failure?.code == "DRAFT_NOT_READY")
        #expect(app.notificationsPath.last?.id == messageID)
        #expect(!message.isClosed)
        #expect(message.session.body.text == "message still on screen")
        post.invalidate()
        message.invalidate()
    }
}
