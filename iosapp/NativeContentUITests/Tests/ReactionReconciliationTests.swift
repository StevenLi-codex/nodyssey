import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test(arguments: [false, true]) @MainActor
func successfulSnapshotLoadNeverReconcilesUnknownSpending(_ extend: Bool) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { operation, _ in
        if operation == "thread.react" { throw NativeFailure(code: "NETWORK", message: "Response lost") }
        // The actual repository can return this unchanged floor after offline fallback or
        // after successfully extending another page. Snapshot membership proves neither read.
        return .object(["postId": .integer(42), "firstLoadedPage": .integer(1),
                        "lastLoadedPage": .integer(2), "commentPages": .array([.integer(1), .integer(2)]),
                        "comments": .array([.object(["commentId": .integer(7), "reactions": .object(["liked": .bool(false)])]),
                                            .object(["commentId": .integer(8)])])])
    }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    await command.loadThread(app, postID: 42, page: 2, extend: extend)
    #expect(command.reactionsBlocked)
    #expect(command.react(app, postID: 42, commentID: 7, action: "ChickenLeg") == nil)
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 1)
}

private func reactionReceipt(post: Int64 = 42, page: Int64 = 2, ids: [Int64] = [7], opening: Int64? = nil) -> JSONValue {
    .object(["postId": .integer(post), "page": .integer(page),
             "commentIds": .array(ids.map(JSONValue.integer)),
             "openingCommentId": opening.map(JSONValue.integer) ?? .null])
}

@Test @MainActor func explicitReadTargetsAffectedPageAndMatchingComment() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Response lost") }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg", page: 2)?.value
    app.respond = { operation, arguments in
        #expect(operation == "thread.reconcileReactions")
        #expect(arguments["page"]?.int == 2)
        return reactionReceipt()
    }
    await command.reconcileReactions(app, postID: 42)
    #expect(!command.reactionsBlocked)
    app.respond = { _, _ in .null }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg", page: 2)?.value
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 2)
}

@Test(arguments: ["network", "wrongPost", "wrongPage", "otherComment", "snapshot", "null", "cancel", "generation", "identity"])
@MainActor func explicitReadFailsClosed(_ outcome: String) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Response lost") }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg", page: 2)?.value
    app.respond = { _, _ in
        switch outcome {
        case "network": throw NativeFailure(code: "NETWORK", message: "Offline")
        case "wrongPost": return reactionReceipt(post: 99)
        case "wrongPage": return reactionReceipt(page: 3)
        case "otherComment": return reactionReceipt(ids: [8])
        case "snapshot": return .object(["postId": .integer(42), "page": .integer(2), "comments": .array([.object(["commentId": .integer(7)])])])
        case "null": return .null
        case "cancel": throw CancellationError()
        case "generation": app.generation += 1
        default: break
        }
        return reactionReceipt()
    }
    await command.reconcileReactions(app, postID: outcome == "identity" ? 99 : 42)
    #expect(command.reactionsBlocked)
    #expect(command.react(app, postID: 42, commentID: 7, action: "ChickenLeg", page: 2) == nil)
}

@Test @MainActor func openingBodyNeedsExplicitOpeningCoverageNotRetainedSnapshotOrCommentList() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Response lost") }
    await command.react(app, postID: 42, commentID: 7, action: "Dislike", page: 3, opening: true)?.value
    app.respond = { _, arguments in
        #expect(arguments["page"]?.int == 1)
        return reactionReceipt(page: 1, ids: [7])
    }
    await command.reconcileReactions(app, postID: 42)
    #expect(command.reactionsBlocked)
    app.respond = { _, _ in reactionReceipt(page: 1, ids: [], opening: 7) }
    await command.reconcileReactions(app, postID: 42)
    #expect(!command.reactionsBlocked)
}
