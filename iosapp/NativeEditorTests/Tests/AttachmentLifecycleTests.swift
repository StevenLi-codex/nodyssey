import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

private struct DrainingSuspendedTransport: NativeTransport {
    let base = SuspendedTransport()
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await base.request(operation, arguments)
    }
    func request(_ operation: String, _ arguments: [String: JSONValue], onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue {
        defer { onTermination() } // This synthetic consumer is the async body itself.
        return try await base.request(operation, arguments)
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { base.observe(operation, arguments) }
    func waitForCall() async { await base.waitForCall() }
    func finish(_ value: JSONValue) async { await base.finish(value) }
}

@Test @MainActor func invalidationKeepsOwnedFileUntilUploadConsumerStops() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let transport = DrainingSuspendedTransport() // explicitly acknowledges its synthetic consumer termination
    let model = EditorViewModel(mode: .message(uid: 803), transport: transport, arguments: [:])
    model.addFile(url)
    model.upload(try #require(model.attachments.first?.id))
    await transport.waitForCall()
    model.invalidate()
    #expect(FileManager.default.fileExists(atPath: url.path))
    await transport.finish(.null)
    try await model.close() // Await the exact teardown rather than scheduling guesses.
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(model.attachments.isEmpty)
}

@Test @MainActor func permanentCloseReleasesFilesButTemporaryFlushDoesNot() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let model = EditorViewModel(mode: .message(uid: 805), transport: RecordingTransport(), arguments: [:])
    await model.load()
    model.addFile(url)
    try await model.flush()
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(model.attachments.count == 1)
    try await model.close()
    #expect(model.isClosed)
    #expect(model.attachments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func cancelledImportDisposesLateCopyAndDoesNotStartNextProvider() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    let gate = SuspendedTransport()
    let model = EditorViewModel(mode: .message(uid: 806), transport: RecordingTransport(), arguments: [:])
    await model.load()
    var cancellationObserved = false
    var nextStarted = false
    model.importFiles([
        {
            _ = try await gate.request("controlled-copy", [:])
            cancellationObserved = Task.isCancelled
            try Data("late-owned-copy".utf8).write(to: url)
            return url
        },
        { nextStarted = true; return url }
    ])
    await gate.waitForCall()
    let close = Task { try await model.close() }
    while !model.isClosed { await Task.yield() }
    await gate.finish(.null)
    try await close.value
    #expect(cancellationObserved)
    #expect(!nextStarted)
    #expect(model.attachments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func permanentCloseCancelsOwnedPreviewRequest() async throws {
    let transport = SlowDraftTransport()
    let model = EditorViewModel(mode: .message(uid: 807), transport: transport, arguments: [:])
    await model.load()
    let preview = Task { await model.showPreview() }
    await transport.waitForStart()
    try await model.close()
    await preview.value
    #expect(await transport.cancellations == 1)
    #expect(model.preview == nil)
    #expect(!model.previewing)
}

@Test @MainActor func latePickerDeliveryAfterInvalidationDeletesOwnedCopy() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let model = EditorViewModel(mode: .message(uid: 804), transport: RecordingTransport(), arguments: [:])
    model.invalidate()
    model.addFile(url)
    #expect(model.attachments.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
