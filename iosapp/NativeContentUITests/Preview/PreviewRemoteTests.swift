import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

private actor RemotePreviewTransport: NativeTransport {
    private(set) var calls: [String] = []
    private(set) var args: [[String: JSONValue]] = []
    let cached: JSONValue
    let remote: JSONValue
    private var held: CheckedContinuation<JSONValue, Error>?
    private let hold: Bool
    init(cached: JSONValue = .null, remote: JSONValue, hold: Bool = false) {
        self.cached = cached; self.remote = remote; self.hold = hold
    }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append(operation); args.append(arguments)
        if operation == "thread.get" { return cached }
        guard operation == "thread.preview" else {
            throw NativeFailure(code: "UNEXPECTED_OPERATION", message: operation)
        }
        if hold { return try await withCheckedThrowingContinuation { held = $0 } }
        return remote
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish(throwing: NativeFailure(code: "UNEXPECTED_OBSERVATION", message: operation)) }
    }
    func waiting() -> Bool { held != nil }
    func release() { held?.resume(returning: remote); held = nil }
}

private func remoteBody(postID: Int64 = 42, page: Int64 = 1) -> JSONValue {
    .object(["postId": .integer(postID), "firstLoadedPage": .integer(page), "lastLoadedPage": .integer(page),
             "body": .object(["nodes": .array([.object(["type": .string("p"), "inlines": .array([])])])])])
}

@MainActor private func remoteOwner(_ app: NativeAppModel) -> ContentPostPreviewOwner {
    .init(postID: 42, generation: app.generation,
          identityEpoch: app.session.nativeString("identityEpoch"), site: app.site.nativeString("current"))
}

@Test @MainActor func previewCacheMissFetchesOnlyReadOnlyPageOneOnDemand() async {
    for cached: JSONValue in [.null, .object(["postId": .integer(42), "body": .null])] {
        let expected = remoteBody()
        let transport = RemotePreviewTransport(cached: cached, remote: expected)
        let app = NativeAppModel(transport: transport)
        let loader = ContentPostPreviewLoader()
        let owner = remoteOwner(app)
        #expect(await transport.calls.isEmpty)
        await loader.load(app, owner: owner)
        await loader.load(app, owner: owner)
        #expect(loader.value == expected)
        #expect(loader.failure == nil)
        #expect(await transport.calls == ["thread.get", "thread.preview"])
        #expect(await transport.args == [["postId": .integer(42)], ["postId": .integer(42)]])
    }
}

@Test @MainActor func previewRemoteRejectsWrongPostAndNonOpeningPage() async {
    for response in [remoteBody(postID: 43), remoteBody(page: 2)] {
        let transport = RemotePreviewTransport(remote: response)
        let app = NativeAppModel(transport: transport)
        let loader = ContentPostPreviewLoader()
        await loader.load(app, owner: remoteOwner(app))
        #expect(loader.value == .null)
        #expect(loader.failure?.code == "INVALID_DATA")
    }
}

@Test @MainActor func previewRemoteLateReplyCannotReviveDismissedOrReplacedIdentity() async {
    for change in 0..<5 {
        let transport = RemotePreviewTransport(remote: remoteBody(), hold: true)
        let app = NativeAppModel(transport: transport)
        let loader = ContentPostPreviewLoader()
        let owner = remoteOwner(app)
        let task = Task { await loader.load(app, owner: owner) }
        // Bounded wait also makes an omitted remote request fail rather than hang.
        for _ in 0..<1000 { if await transport.waiting() { break }; await Task.yield() }
        #expect(await transport.waiting())
        if change == 0 { loader.cancel(owner) }
        if change == 1 { app.generation += 1 }
        if change == 2 { app.session = .object(["identityEpoch": .string("b")]) }
        if change == 3 { app.site = .object(["current": .string("DEEPNODE")]) }
        if change == 4 { task.cancel() }
        await transport.release()
        await task.value
        await loader.load(app, owner: owner)
        #expect(loader.value == .null)
        #expect(!loader.isLoading)
        #expect(await transport.calls == ["thread.get", "thread.preview"])
    }
}
