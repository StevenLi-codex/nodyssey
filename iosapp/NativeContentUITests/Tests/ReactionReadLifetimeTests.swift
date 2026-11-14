import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

private let freshReactionRead: JSONValue = .object([
    "postId": .integer(42), "page": .integer(1), "commentIds": .array([.integer(7)]), "openingCommentId": .null
])

@Test(arguments: ["cancel", "generation", "laterMutation"])
@MainActor func lateNetworkReadCannotClearInvalidatedReaction(_ reason: String) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Response lost") }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    var pending: CheckedContinuation<JSONValue, Never>?
    app.respond = { _, _ in await withCheckedContinuation { pending = $0 } }
    let read = Task { await command.reconcileReactions(app, postID: 42) }
    while pending == nil { await Task.yield() }
    switch reason {
    case "cancel": read.cancel()
    case "generation": app.generation += 1
    default:
        app.respond = { _, _ in freshReactionRead }
        await command.reconcileReactions(app, postID: 42)
        #expect(!command.reactionsBlocked)
        app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Second response lost") }
        await command.react(app, postID: 42, commentID: 9, action: "ChickenLeg", page: 2)?.value
    }
    pending?.resume(returning: freshReactionRead)
    await read.value
    #expect(command.reactionsBlocked)
}

@Test @MainActor func cancellationOfDispatchedReactionBlocksUntilNewNetworkRead() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: CheckedContinuation<JSONValue, any Error>?
    app.respond = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
    let send = command.react(app, postID: 42, commentID: 7, action: "Dislike")
    while pending == nil { await Task.yield() }
    command.cancel()
    pending?.resume(throwing: CancellationError())
    await send?.value
    #expect(command.reactionsBlocked)
    #expect(command.failure == nil)
    app.respond = { _, _ in freshReactionRead }
    await command.reconcileReactions(app, postID: 42)
    #expect(!command.reactionsBlocked)
}
