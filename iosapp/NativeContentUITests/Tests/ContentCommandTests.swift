import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

/// No network or live spending: only the bridge boundary is scripted.
@MainActor final class ScriptedContentContext: ContentCommandContext {
    var generation = 0
    var calls: [(String, [String: JSONValue])] = []
    var respond: @MainActor (String, [String: JSONValue]) async throws -> JSONValue = { _, _ in .null }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((operation, arguments))
        return try await respond(operation, arguments)
    }
}

@Test @MainActor func failedReactionStaysBlockedAfterTrackBookmarkAndLocalConfigUntilRealReload() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { operation, _ in
        if operation == "thread.react" { throw NativeFailure(code: "NETWORK", message: "Indeterminate") }
        return .object(["postId": .integer(42)])
    }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    #expect(command.reactionsBlocked)
    for operation in ["tracked.add", "thread.collect", "thread.config"] {
        await command.run(app) { _ = try await app.request(operation, ["postId": .integer(42)]) }?.value
        #expect(command.failure == nil)
        #expect(command.reactionsBlocked, "Unrelated \(operation) must not reconcile an uncertain reaction")
    }
    await command.loadThread(app, postID: 42, page: 1, extend: false)
    #expect(command.reactionsBlocked)
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 1)
    #expect(app.calls.last?.0 == "thread.load")
}

@Test @MainActor func reloadStartedBeforeReactionCannotReconcileItsLaterFailure() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pendingLoad: CheckedContinuation<JSONValue, Never>?
    app.respond = { operation, _ in
        if operation == "thread.load" { return await withCheckedContinuation { pendingLoad = $0 } }
        throw NativeFailure(code: "NETWORK", message: "Indeterminate")
    }
    let load = Task { await command.loadThread(app, postID: 42, page: 1, extend: false) }
    while pendingLoad == nil { await Task.yield() }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    #expect(command.reactionsBlocked)
    pendingLoad?.resume(returning: .object(["postId": .integer(42)]))
    await load.value
    #expect(command.reactionsBlocked, "An older refresh cannot reconcile a later indeterminate mutation")
}

@Test(arguments: ["failure", "null", "wrongThread", "session", "cancelled"])
@MainActor func incompleteReloadCannotUnlockReaction(_ outcome: String) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Indeterminate") }
    await command.react(app, postID: 42, commentID: 7, action: "Dislike")?.value
    app.respond = { _, _ in
        switch outcome {
        case "failure": throw NativeFailure(code: "NETWORK", message: "Load failed")
        case "null": return .null
        case "wrongThread": return .object(["postId": .integer(99)])
        case "session": app.generation += 1
        case "cancelled": throw CancellationError()
        default: break
        }
        return .object(["postId": .integer(42)])
    }
    await command.loadThread(app, postID: 42, page: 1, extend: false)
    #expect(command.reactionsBlocked)
    #expect(command.react(app, postID: 42, commentID: 7, action: "Dislike") == nil)
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 1)
}
