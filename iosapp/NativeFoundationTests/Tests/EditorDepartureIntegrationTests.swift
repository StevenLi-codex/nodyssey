import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct EditorDepartureIntegrationTests {
    @Test func outerCloseAwaitsDraftSaveWhileUploadLeaseSurvivesSwiftCancellation() async throws {
        var terminate: (@Sendable () -> Void)?
        var save: (@Sendable (String) -> Void)?
        let transport = CallbackNativeTransport(drainingRequest: { operation, _, result, drained in
            if operation == "editor.image.upload" { terminate = drained }
            else if operation == "draft.post.save" { save = { response in result(response); drained() } }
            else { result("{\"ok\":true,\"data\":null}"); drained() }
            return NativeCancellation {}
        }, observe: { _, _, _ in NativeCancellation {} })
        let app = NativeAppModel(transport: transport)
        app.showSignIn()
        app.open("PostComposer")
        let id = try #require(app.sheetPath.last?.id)
        let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: id)
        await model.load()
        model.session.changeBody(EditorBuffer(text: "draft"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.addFile(file)
        model.upload(try #require(model.attachments.first?.id))
        try await eventually { terminate != nil }
        let close = Task { await app.dismissSheet() }
        try await eventually { save != nil }
        #expect(app.sheet != nil)
        #expect(!model.isClosed)
        save?("{\"ok\":true,\"data\":null}")
        await close.value
        #expect(app.sheet == nil)
        #expect(model.isClosed)
        #expect(FileManager.default.fileExists(atPath: file.path))
        terminate?()
        try await eventually { !FileManager.default.fileExists(atPath: file.path) }
    }

    @Test func rootIdentityRemovalRetainsUploadingFileUntilPlatformTermination() async throws {
        var terminate: (@Sendable () -> Void)?
        var operations: [String] = []
        let transport = CallbackNativeTransport(drainingRequest: { operation, _, result, drained in
            operations.append(operation)
            if operation == "editor.image.upload" { terminate = drained }
            else { result("{\"ok\":true,\"data\":null}"); drained() }
            return NativeCancellation {}
        }, observe: { _, _, _ in NativeCancellation {} })
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        app.open("PostComposer")
        let id = try #require(app.homePath.last?.id)
        let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.addFile(file)
        model.upload(try #require(model.attachments.first?.id))
        try await eventually { terminate != nil }
        app.session = boundarySession(.string("process-B"))
        for _ in 0..<30 { await Task.yield() }
        #expect(model.isClosed)
        #expect(app.homePath.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!operations.contains("draft.post.save"))
        terminate?()
        try await eventually { !FileManager.default.fileExists(atPath: file.path) }
    }

    @Test func realEditorRegistrationRefusesPendingLoadAndUnresolvedDraftDuringSheetReplacement() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.showSignIn()
        app.open("PostComposer")
        let id = try #require(app.sheetPath.last?.id)
        let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: id)
        model.session.changeBody(EditorBuffer(text: "B"))
        await app.dismissSheet()
        #expect(app.sheetPath.last?.id == id)
        #expect(model.failure?.code == "DRAFT_NOT_READY")
        let load = Task { await model.load() }
        try await eventually { transport.hasRequest("draft.post.get") }
        transport.resolve("draft.post.get", .success(.object(["body": .string("A")])))
        await load.value
        app.open("Web", ["goal": .string("CHALLENGE")])
        try await eventually { owner.needsDraftDecision }
        #expect(app.sheet?.route == "SignIn")
        #expect(app.sheetPath.last?.id == id)
        #expect(model.session.body.text == "B")
        #expect(transport.arguments(for: "draft.post.save").isEmpty)
        model.invalidate()
    }

    @Test func realEditorFailedSaveAndNewerInputKeepRouteUntilAwaitedCloseSucceeds() async throws {
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
        model.session.changeBody(EditorBuffer(text: "B"))
        let failed = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.post.save") }
        #expect(app.homePath.last?.id == id)
        transport.resolve("draft.post.save", .failure(NativeFailure(code: "NETWORK", message: "fixture")))
        await failed.value
        #expect(!model.isClosed)
        #expect(app.homePath.last?.id == id)
        let changed = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.post.save") }
        model.session.changeBody(EditorBuffer(text: "C"))
        transport.resolve("draft.post.save", .success(.null))
        await changed.value
        #expect(model.failure?.code == "DRAFT_CHANGED")
        #expect(app.homePath.last?.id == id)
        let success = Task { await app.updatePath([], for: .home) }
        try await eventually { transport.hasRequest("draft.post.save") }
        transport.resolve("draft.post.save", .success(.null))
        await success.value
        #expect(model.isClosed)
        #expect(app.homePath.isEmpty)
    }

    @Test func realEditorIdentityRevocationDoesNotSaveAndLatePickerCannotAttach() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        app.open("PostComposer")
        let id = try #require(app.homePath.last?.id)
        let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
        let owner = NativeEditorRouteLifetime(model: model)
        owner.register(app: app, destinationID: id)
        model.session.changeBody(EditorBuffer(text: "old account draft"))
        var picker: CheckedContinuation<URL, Never>?
        model.importFiles([{ await withCheckedContinuation { picker = $0 } }])
        try await eventually { picker != nil }
        app.session = boundarySession(.string("process-B"))
        #expect(model.isClosed)
        #expect(app.homePath.isEmpty)
        #expect(transport.arguments(for: "draft.post.save").isEmpty)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        picker?.resume(returning: file)
        try await eventually { !FileManager.default.fileExists(atPath: file.path) }
        #expect(model.attachments.isEmpty)
    }
}
