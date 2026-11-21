import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

private actor PreviewTransport: NativeTransport {
    private(set) var operations: [String] = []
    private(set) var arguments: [[String: JSONValue]] = []
    private var pending: CheckedContinuation<JSONValue, Error>?
    func request(_ operation: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        operations.append(operation); arguments.append(args)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    nonisolated func observe(_ operation: String, _ args: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish(throwing: NativeFailure(code: "UNEXPECTED_OBSERVATION", message: operation)) }
    }
    func finish(_ value: JSONValue) { pending?.resume(returning: value); pending = nil }
    func fail() { pending?.resume(throwing: NativeFailure(code: "CACHE_READ_FAILED", message: "Fixture")); pending = nil }
    func waitForRead() async {
        while pending == nil { await Task.yield() }
    }
}

@MainActor private func previewOwner(_ app: NativeAppModel, postID: Int64 = 42) -> ContentPostPreviewOwner {
    .init(postID: postID, generation: app.generation,
          identityEpoch: app.session["identityEpoch"]?.string, site: app.site["current"]?.string)
}

@Test @MainActor func previewRejectsWrongPostReturnedByCacheBoundary() async {
    let transport = PreviewTransport()
    let app = NativeAppModel(transport: transport)
    let loader = ContentPostPreviewLoader()
    let task = Task { await loader.load(app, owner: previewOwner(app)) }
    await transport.waitForRead()
    await transport.finish(.object(["postId": .integer(43), "title": .string("Other account or cell")]))
    await task.value
    #expect(loader.value == .null)
    #expect(loader.failure?.code == "INVALID_DATA")
}

@Test @MainActor func previewOnlyReadsOnDemandOnceAndPreservesExactIdentity() async {
    let transport = PreviewTransport()
    let app = NativeAppModel(transport: transport)
    let loader = ContentPostPreviewLoader()
    #expect(await transport.operations.isEmpty)
    let postID: Int64 = 9007199254740993
    let owner = previewOwner(app, postID: postID)
    let task = Task { await loader.load(app, owner: owner) }
    await transport.waitForRead()
    let cached: JSONValue = .object(["postId": .integer(postID), "title": .string("Title"),
        "body": .object(["nodes": .array([.object(["type": .string("p"), "inlines": .array([])])])])])
    await transport.finish(cached)
    await task.value
    await loader.load(app, owner: owner)
    #expect(loader.value == cached)
    #expect(loader.failure == nil)
    #expect(!loader.isLoading)
    #expect(await transport.operations == ["thread.get"])
    #expect(await transport.arguments == [["postId": .integer(postID)]])
}

@Test @MainActor func previewCancellationBeforeAppearanceCannotStartARequest() async {
    let transport = PreviewTransport()
    let app = NativeAppModel(transport: transport)
    let loader = ContentPostPreviewLoader()
    let owner = previewOwner(app)
    loader.cancel(owner)
    await loader.load(app, owner: owner)
    #expect(await transport.operations.isEmpty)
    #expect(loader.value == .null)
}

@Test @MainActor func previewDismissalDiscardsNoncooperativeLateReply() async {
    let transport = PreviewTransport()
    let app = NativeAppModel(transport: transport)
    let loader = ContentPostPreviewLoader()
    let owner = previewOwner(app)
    let task = Task { await loader.load(app, owner: owner) }
    await transport.waitForRead()
    loader.cancel(owner)
    await transport.finish(.object(["postId": .integer(42), "title": .string("Late")]))
    await task.value
    #expect(loader.value == .null)
    #expect(loader.failure == nil)
    #expect(!loader.isLoading)
}

@Test @MainActor func previewFencesGenerationEpochAndSiteBeforePublishing() async {
    for change in 0..<3 {
        let transport = PreviewTransport()
        let app = NativeAppModel(transport: transport)
        let loader = ContentPostPreviewLoader()
        let owner = previewOwner(app)
        let task = Task { await loader.load(app, owner: owner) }
        await transport.waitForRead()
        if change == 0 { app.generation += 1 }
        if change == 1 { app.session = .object(["identityEpoch": .string("epoch-b")]) }
        if change == 2 { app.site = .object(["current": .string("DEEPNODE")]) }
        await transport.finish(.object(["postId": .integer(42), "title": .string("Stale")]))
        await task.value
        #expect(loader.value == .null)
        #expect(!loader.isLoading)
    }
}

@Test @MainActor func previewDistinguishesCacheMissFailureAndARealBody() async {
    let missingTransport = PreviewTransport()
    let app = NativeAppModel(transport: missingTransport)
    let missing = ContentPostPreviewLoader()
    let task = Task { await missing.load(app, owner: previewOwner(app)) }
    await missingTransport.waitForRead()
    await missingTransport.finish(.null)
    await missingTransport.waitForRead() // The read-only remote endpoint also has no body.
    await missingTransport.finish(.null)
    await task.value
    #expect(missing.value == .null)
    #expect(missing.failure == nil) // Honest cache miss, not fake body success.
    let failingTransport = PreviewTransport()
    let failingApp = NativeAppModel(transport: failingTransport)
    let failing = ContentPostPreviewLoader()
    let failureTask = Task { await failing.load(failingApp, owner: previewOwner(failingApp)) }
    await failingTransport.waitForRead()
    await failingTransport.fail()
    await failureTask.value
    #expect(failing.value == .null)
    #expect(failing.failure?.code == "CACHE_READ_FAILED")
}

@Test func oldMenuCancellationCannotRevokeNewMenuLease() {
    let old = ContentPostPreviewOwner(postID: 42, generation: 4, identityEpoch: "a", site: "NODESEEK")
    let newer = ContentPostPreviewOwner(postID: 42, generation: 4, identityEpoch: "a", site: "NODESEEK")
    var lease = ContentPostPreviewLease()
    lease.begin(old); lease.begin(newer); lease.cancel(old)
    #expect(!lease.accepts(old, postID: 42, generation: 4, identityEpoch: "a", site: "NODESEEK"))
    #expect(lease.accepts(newer, postID: 42, generation: 4, identityEpoch: "a", site: "NODESEEK"))
    lease.cancel(newer)
    #expect(!lease.accepts(newer, postID: 42, generation: 4, identityEpoch: "a", site: "NODESEEK"))
}
