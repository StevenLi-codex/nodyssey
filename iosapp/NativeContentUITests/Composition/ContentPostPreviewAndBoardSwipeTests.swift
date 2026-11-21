import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test func homeBoardSwipeMovesOneVisibleNeighborAndHonorsRTL() {
    let owner = ContentFeedBoardSwipeOwner(
        generation: 4, identityEpoch: "epoch-a", board: "", orderedBoards: ["", "tech", "life"], isHomeRoot: true
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: -100, translationY: 4, rightToLeft: false
    ) == "tech")
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: 100, translationY: 4, rightToLeft: false
    ) == nil)
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: 100, translationY: 4, rightToLeft: true
    ) == "tech")
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: -100, translationY: 4, rightToLeft: true
    ) == nil)
}

@Test func homeBoardSwipeRejectsVerticalShortEdgeAndStaleOwners() {
    let owner = ContentFeedBoardSwipeOwner(
        generation: 4, identityEpoch: "epoch-a", board: "tech", orderedBoards: ["", "tech", "life"], isHomeRoot: true
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: -40, translationY: 2, rightToLeft: false
    ) == nil)
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: -100, translationY: 90, rightToLeft: false
    ) == nil)
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: owner, translationX: -100, translationY: 2, rightToLeft: false
    ) == "life")

    let changedSession = ContentFeedBoardSwipeOwner(
        generation: 5, identityEpoch: "epoch-b", board: "tech", orderedBoards: owner.orderedBoards, isHomeRoot: true
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: changedSession, translationX: -100, translationY: 2, rightToLeft: false
    ) == nil)
    let navigated = ContentFeedBoardSwipeOwner(
        generation: 4, identityEpoch: "epoch-a", board: "tech", orderedBoards: owner.orderedBoards, isHomeRoot: false
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: owner, current: navigated, translationX: -100, translationY: 2, rightToLeft: false
    ) == nil)
}

@Test func homeBoardSwipeUsesVisibleOrderAndNeverWrapsOrMovesFromHiddenBoard() {
    let first = ContentFeedBoardSwipeOwner(
        generation: 4, identityEpoch: "epoch-a", board: "", orderedBoards: ["", "life", "tech"], isHomeRoot: true
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: first, current: first, translationX: -100, translationY: 0, rightToLeft: false
    ) == "life")
    #expect(ContentFeedBoardSwipe.destination(
        start: first, current: first, translationX: 100, translationY: 0, rightToLeft: false
    ) == nil)

    let hidden = ContentFeedBoardSwipeOwner(
        generation: 4, identityEpoch: "epoch-a", board: "hidden", orderedBoards: ["", "life", "tech"], isHomeRoot: true
    )
    #expect(ContentFeedBoardSwipe.destination(
        start: hidden, current: hidden, translationX: -100, translationY: 0, rightToLeft: false
    ) == nil)
}

@Test func previewProjectionRequiresMatchingCachedThreadAndRealBodyNodes() {
    let postID: Int64 = 9007199254740993
    let summary: JSONValue = .object(["postId": .integer(postID), "title": .string("Feed title")])
    let node: JSONValue = .object([
        "type": .string("p"),
        "inlines": .array([.object(["type": .string("t"), "text": .string("Cached body text")])])
    ])
    let cached: JSONValue = .object([
        "postId": .integer(postID), "title": .string("Cached title"),
        "body": .object(["nodes": .array([node])])
    ])
    let preview = ContentPostPreviewContent(postID: postID, summary: summary, thread: cached)
    #expect(preview.title == "Cached title")
    #expect(preview.nodes == [node])
    #expect(preview.hasBody)

    let missing = ContentPostPreviewContent(postID: postID, summary: summary, thread: .null)
    #expect(missing.title == "Feed title")
    #expect(missing.nodes.isEmpty)
    #expect(!missing.hasBody)

    let wrongOwner = ContentPostPreviewContent(
        postID: postID, summary: summary,
        thread: .object(["postId": .integer(postID + 1), "title": .string("Other post"), "body": .object(["nodes": .array([node])])])
    )
    #expect(wrongOwner.title == "Feed title")
    #expect(wrongOwner.nodes.isEmpty)
    #expect(!wrongOwner.hasBody)
}

@Test func previewOwnerFencesGenerationIdentityAndSiteChanges() {
    let owner = ContentPostPreviewOwner(postID: 42, generation: 4, identityEpoch: "epoch-a", site: "nodesseek")
    #expect(owner.matches(postID: 42, generation: 4, identityEpoch: "epoch-a", site: "nodesseek"))
    #expect(!owner.matches(postID: 43, generation: 4, identityEpoch: "epoch-a", site: "nodesseek"))
    #expect(!owner.matches(postID: 42, generation: 5, identityEpoch: "epoch-a", site: "nodesseek"))
    #expect(!owner.matches(postID: 42, generation: 4, identityEpoch: "epoch-b", site: "nodesseek"))
    #expect(!owner.matches(postID: 42, generation: 4, identityEpoch: "epoch-a", site: "other"))
}

@Test func homeBoardSwipeLocksFirstAxisAndCancelsBeforeANewGesture() {
    let owner = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "",
        orderedBoards: ["", "tech"], isHomeRoot: true, site: "NODESEEK")
    var trace = ContentFeedBoardSwipeTrace()
    trace.record(owner, x: 1, y: 20)
    trace.record(owner, x: -100, y: 22)
    #expect(trace.finish(current: owner, x: -100, y: 22, rightToLeft: false) == nil)
    #expect(trace.owner == nil)
    trace.record(owner, x: -20, y: 1)
    trace.cancel()
    #expect(trace.finish(current: owner, x: -100, y: 1, rightToLeft: false) == nil)
    trace.record(owner, x: -20, y: 1)
    #expect(trace.finish(current: owner, x: -100, y: 1, rightToLeft: false) == "tech")
}

@Test func homeBoardSwipeRejectsBoardRemovalOrderOrSiteChangeDuringGesture() {
    let owner = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true, site: "NODESEEK")
    var siteChanged = owner; siteChanged.site = "DEEPNODE"
    let removed = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "life"], isHomeRoot: true, site: "NODESEEK")
    let reordered = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "life", "tech"], isHomeRoot: true, site: "NODESEEK")
    for changed in [siteChanged, removed, reordered] {
        #expect(ContentFeedBoardSwipe.destination(start: owner, current: changed,
            translationX: -100, translationY: 0, rightToLeft: false) == nil)
    }
    #expect(ContentFeedBoardSwipe.destination(start: owner, current: owner,
        translationX: .nan, translationY: 0, rightToLeft: false) == nil)
}

@Test func previewBlockedBodyNeverExposesCachedNodes() {
    let thread: JSONValue = .object(["postId": .integer(42), "title": .string("Title"),
        "body": .object(["isBlocked": .bool(true), "nodes": .array([.object(["type": .string("p")])])])])
    let content = ContentPostPreviewContent(postID: 42, summary: .null, thread: thread)
    #expect(content.isBlocked)
    #expect(content.nodes.isEmpty)
    #expect(!content.hasBody)
}
