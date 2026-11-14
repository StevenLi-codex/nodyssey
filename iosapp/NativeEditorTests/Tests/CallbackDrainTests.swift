import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

/// Production callback adapter, not an async fake that implicitly joins on cancel.
@MainActor private final class PlatformUpload {
    var result: (@Sendable (String) -> Void)?
    var cancelled = false
    var duringStart: (() -> Void)?
    var termination: (@Sendable () -> Void)?
    func transport() -> CallbackNativeTransport {
        CallbackNativeTransport(drainingRequest: { _, _, result, terminated in
            self.termination = terminated
            return self.start(result)
        }, observe: { _, _, _ in NativeCancellation {} })
    }
    func terminate() { termination?() }
    var started: CheckedContinuation<Void, Never>?
    func waitForStart() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func start(_ completion: @escaping @Sendable (String) -> Void) -> NativeCancellation {
        result = completion
        duringStart?()
        started?.resume(); started = nil
        return NativeCancellation { Task { @MainActor in self.cancelled = true } }
    }
}

@Test @MainActor func callbackCancellationWithoutDrainRetainsSource() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("owned source".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    let transport = CallbackNativeTransport(request: { _, _, result in platform.start(result) }, observe: { _, _, _ in NativeCancellation {} })
    let model = EditorViewModel(mode: .message(uid: 810), transport: transport, arguments: [:])
    model.addFile(source)
    model.upload(try #require(model.attachments.first?.id))
    await platform.waitForStart()
    model.invalidate()
    try await model.close()
    // Swift continuation has unwound, but no platform termination is available.
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(model.attachments.isEmpty)
}

@Test @MainActor func platformCancellationReturnsBeforeReaderTermination() async throws {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("reader still needs these bytes".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    var model: EditorViewModel? = EditorViewModel(mode: .message(uid: 811), transport: platform.transport(), arguments: [:])
    model!.addFile(source)
    model!.upload(try #require(model!.attachments.first?.id))
    await platform.waitForStart()
    model!.invalidate() // same path used by generation invalidation
    try await model!.close() // Swift upload task has completed, not the platform reader
    while !platform.cancelled { await Task.yield() }
    #expect(FileManager.default.fileExists(atPath: source.path))
    weak var releasedModel = model
    model = nil
    #expect(releasedModel == nil)
    releasedModel = nil
    platform.result?("{\"ok\":true,\"data\":null}") // late UI result is not termination
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try String(contentsOf: source) == "reader still needs these bytes")
    platform.terminate()
    #expect(!FileManager.default.fileExists(atPath: source.path))
    platform.terminate() // duplicate acknowledgement must not touch a reused path
    try Data("replacement".utf8).write(to: source)
    platform.terminate()
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test @MainActor func normalUploadResultThenRemovalWaitsForFinally() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    let model = EditorViewModel(mode: .message(uid: 812), transport: platform.transport(), arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    model.upload(id)
    await platform.waitForStart()
    platform.result?("{\"ok\":true,\"data\":{\"id\":\"\(id.uuidString)\",\"markdown\":\"![image](https://example.invalid/image)\"}}")
    while model.attachments.first?.phase == .uploading { await Task.yield() }
    #expect(model.attachments.first?.phase == .uploaded)
    model.removeAttachment(id)
    #expect(model.attachments.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
    platform.terminate()
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test @MainActor func drainedUploadRetainsAttachmentUntilUserRemovesIt() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    let model = EditorViewModel(mode: .message(uid: 813), transport: platform.transport(), arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    model.upload(id)
    await platform.waitForStart()
    platform.result?("{\"ok\":true,\"data\":{\"id\":\"\(id.uuidString)\",\"markdown\":\"image\"}}")
    platform.terminate()
    while model.attachments.first?.phase == .uploading { await Task.yield() }
    #expect(FileManager.default.fileExists(atPath: source.path))
    model.removeAttachment(id)
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test @MainActor func removingActiveUploadKeepsSourceUntilSeparateTermination() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    let model = EditorViewModel(mode: .message(uid: 814), transport: platform.transport(), arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    model.upload(id)
    await platform.waitForStart()
    model.removeAttachment(id)
    while !platform.cancelled { await Task.yield() }
    #expect(model.attachments.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
    try await model.close()
    #expect(FileManager.default.fileExists(atPath: source.path))
    platform.terminate()
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test @MainActor func invalidatedGenerationLateCompletionDoesNotAffectNewEditor() async throws {
    let oldSource = try ownedDrainFixture(), newSource = try ownedDrainFixture()
    defer {
        try? FileManager.default.removeItem(at: oldSource)
        try? FileManager.default.removeItem(at: newSource)
    }
    let oldPlatform = PlatformUpload(), newPlatform = PlatformUpload()
    let oldModel = EditorViewModel(mode: .message(uid: 815), transport: oldPlatform.transport(), arguments: [:])
    oldModel.addFile(oldSource)
    let oldID = try #require(oldModel.attachments.first?.id)
    oldModel.upload(oldID)
    await oldPlatform.waitForStart()
    oldModel.invalidate()
    try await oldModel.close()
    let newModel = EditorViewModel(mode: .message(uid: 816), transport: newPlatform.transport(), arguments: [:])
    newModel.addFile(newSource)
    newModel.session.changeBody(EditorBuffer(text: "new identity input"))
    oldPlatform.result?("{\"ok\":true,\"data\":{\"id\":\"\(oldID.uuidString)\",\"markdown\":\"stale\"}}")
    oldPlatform.terminate()
    #expect(!FileManager.default.fileExists(atPath: oldSource.path))
    #expect(FileManager.default.fileExists(atPath: newSource.path))
    #expect(oldModel.attachments.isEmpty)
    #expect(oldModel.failure == nil)
    #expect(newModel.session.body.text == "new identity input")
    #expect(newModel.attachments.first?.phase == .waiting)
    newModel.invalidate()
}

@Test @MainActor func removalDuringPlatformStartBeforeHandleInstallationKeepsFile() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let platform = PlatformUpload()
    let model = EditorViewModel(mode: .message(uid: 817), transport: platform.transport(), arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    platform.duringStart = { model.removeAttachment(id) }
    model.upload(id)
    await platform.waitForStart()
    while !platform.cancelled { await Task.yield() }
    try await model.close()
    #expect(FileManager.default.fileExists(atPath: source.path))
    platform.terminate()
    #expect(!FileManager.default.fileExists(atPath: source.path))
    platform.duringStart = nil
}

@Test @MainActor func retryCannotReleasePreviousAttemptStillInFinally() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let first = PlatformUpload(), second = PlatformUpload()
    var starts = 0
    let transport = CallbackNativeTransport(drainingRequest: { _, _, result, terminated in
        let platform = starts == 0 ? first : second
        starts += 1
        platform.termination = terminated
        return platform.start(result)
    }, observe: { _, _, _ in NativeCancellation {} })
    let model = EditorViewModel(mode: .message(uid: 818), transport: transport, arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    model.upload(id)
    await first.waitForStart()
    first.result?(#"{"ok":false,"error":{"code":"INTERNAL","message":"failed"}}"#)
    while model.attachments.first?.phase == .uploading { await Task.yield() }
    #expect(model.attachments.first?.phase == .failed)
    model.upload(id)
    await second.waitForStart()
    model.removeAttachment(id)
    try await model.close()
    second.terminate()
    #expect(FileManager.default.fileExists(atPath: source.path))
    first.terminate()
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

private struct LegacyFileTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        .object(["id": arguments["id"] ?? .null, "markdown": .string("legacy result")])
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Test @MainActor func legacyDefaultTransportCannotPretendSuccessfulReturnIsDrain() async throws {
    let source = try ownedDrainFixture()
    defer { try? FileManager.default.removeItem(at: source) }
    let model = EditorViewModel(mode: .message(uid: 819), transport: LegacyFileTransport(), arguments: [:])
    model.addFile(source)
    let id = try #require(model.attachments.first?.id)
    model.upload(id)
    while model.attachments.first?.phase == .uploading { await Task.yield() }
    #expect(model.attachments.first?.phase == .uploaded)
    model.removeAttachment(id)
    try await model.close()
    #expect(FileManager.default.fileExists(atPath: source.path))
}

private func ownedDrainFixture() throws -> URL {
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("synthetic source, never uploaded".utf8).write(to: source)
    return source
}
