import Foundation
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
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: owner.scope, current: owner), x: 1, y: 20, rightToLeft: false, now: 1)
    trace.change(gesture: gesture1, context: .init(scope: owner.scope, current: owner), x: -100, y: 22)
    #expect(trace.finish(gesture: gesture1, context: .init(scope: owner.scope, current: owner), x: -100, y: 22, now: 1) == nil)
    #expect(trace.gestureID == nil)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: .init(scope: owner.scope, current: owner), x: -20, y: 1, rightToLeft: false, now: 2)
    trace.cancel()
    #expect(trace.finish(gesture: gesture2, context: .init(scope: owner.scope, current: owner), x: -100, y: 1, now: 2) == nil)
    let gesture3 = UUID()
    trace.begin(gesture: gesture3, context: .init(scope: owner.scope, current: owner), x: -20, y: 1, rightToLeft: false, now: 3)
    #expect(trace.finish(gesture: gesture3, context: .init(scope: owner.scope, current: owner), x: -100, y: 1, now: 3) == "tech")
}

@Test func homeBoardSwipeFollowsTheFingerAndChangesNeighborOnReversal() throws {
    let current = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true)
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: current.scope, current: current), x: -24, y: 1, rightToLeft: false, now: 0, pageWidth: 384)
    let start = try #require(trace.presentation(board: current.board, now: 0))
    trace.change(gesture: gesture1, context: .init(scope: current.scope, current: current), x: -48, y: 2)
    let forward = try #require(trace.presentation(board: current.board, now: 0.02))
    #expect(start.offset < 0 && forward.offset < start.offset)
    #expect(start.boardPosition == 1.0625)
    #expect(forward.boardPosition == 1.125)
    trace.change(gesture: gesture1, context: .init(scope: current.scope, current: current), x: 0, y: 2)
    let neutral = try #require(trace.presentation(board: current.board, now: 0.03))
    #expect(neutral.offset == 0 && neutral.boardPosition == 1)
    trace.change(gesture: gesture1, context: .init(scope: current.scope, current: current), x: 28, y: 2)
    let reversed = try #require(trace.presentation(board: current.board, now: 0.04))
    #expect(reversed.offset > 0 && reversed.boardPosition < 1)
    #expect(trace.gestureID == gesture1)
}

@Test func homeBoardSwipeLivePresentationRespectsAxisRTLAndBoardEdges() throws {
    let first = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "",
        orderedBoards: ["", "tech"], isHomeRoot: true)
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: first.scope, current: first), x: 2, y: 20, rightToLeft: false, now: 0)
    trace.change(gesture: gesture1, context: .init(scope: first.scope, current: first), x: -100, y: 20)
    #expect(trace.presentation(board: first.board, now: 0.1) == nil)
    trace.cancel()
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: .init(scope: first.scope, current: first), x: 22, y: 1, rightToLeft: false, now: 0.2)
    let edge = try #require(trace.presentation(board: first.board, now: 0.2))
    #expect(edge.offset == 0 && edge.boardPosition == 0)
    trace.cancel()
    let gesture3 = UUID()
    trace.begin(gesture: gesture3, context: .init(scope: first.scope, current: first), x: 22, y: 1, rightToLeft: true, now: 0.3)
    let rtl = try #require(trace.presentation(board: first.board, now: 0.3))
    #expect(rtl.offset > 0 && rtl.boardPosition > 0)
}

@Test func homeBoardSwipeCommitsOnReleaseAndRegrabsTheCurrentPose() throws {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true)
    let destination = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "life",
        orderedBoards: source.orderedBoards, isHomeRoot: true, observation: UUID())
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -78, y: 2, rightToLeft: false, now: 0)
    let held = try #require(trace.presentation(board: source.board, now: 0))
    #expect(trace.finish(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -78, y: 2, now: 0.01) == destination.board)
    #expect(trace.presentation(board: destination.board, now: 0.01) == held)
    let inFlight = try #require(trace.presentation(board: destination.board, now: 0.05))
    #expect(inFlight.offset > held.offset && inFlight.offset < 0)
    #expect(inFlight.boardPosition >= held.boardPosition && inFlight.boardPosition <= 2)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: .init(scope: destination.scope, current: destination), x: 12, y: 1, rightToLeft: false, now: 0.05)
    #expect(trace.presentation(board: destination.board, now: 0.05) == inFlight)
    #expect(trace.settleID == nil)
    trace.change(gesture: gesture2, context: .init(scope: destination.scope, current: destination), x: 36, y: 1)
    let reversed = try #require(trace.presentation(board: destination.board, now: 0.06))
    #expect(reversed.offset > inFlight.offset && reversed.boardPosition < inFlight.boardPosition)
}

@Test func homeBoardSwipeShortReleaseAndSystemCancelReturnWithoutCommitting() throws {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true)
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -34, y: 1, rightToLeft: false, now: 0)
    let held = try #require(trace.presentation(board: source.board, now: 0))
    #expect(trace.finish(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -34, y: 1, now: 0.01) == nil)
    #expect(trace.presentation(board: source.board, now: 0.01) == held)
    let returning = try #require(trace.presentation(board: source.board, now: 0.08))
    #expect(returning.offset > held.offset && returning.offset < 0)
    #expect(returning.boardPosition < held.boardPosition && returning.boardPosition > 1)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: .init(scope: source.scope, current: source), x: 14, y: 1, rightToLeft: false, now: 0.08)
    trace.cancel(gesture: gesture2, now: 0.09)
    let canceled = try #require(trace.presentation(board: source.board, now: 0.09))
    #expect(canceled == returning)
    #expect(trace.finish(gesture: gesture2, context: .init(scope: source.scope, current: source), x: 100, y: 1, now: 0.10) == nil)
    #expect(trace.presentation(board: source.board, now: 1) == nil)
}

@Test func homeBoardSwipeMotionPolicyStillAllowsExplicitBoardCommit() {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "",
        orderedBoards: ["", "tech"], isHomeRoot: true)
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -85, y: 1, rightToLeft: false, now: 0, animated: false)
    #expect(trace.presentation(board: source.board, now: 0) == nil)
    #expect(trace.finish(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -85, y: 1, now: 0.01) == "tech")
    #expect(trace.settleID == nil)
}

@Test func homeBoardSwipeOnlyCarriesCommittedMotionAcrossItsMatchingNewPager() {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true, site: "NODESEEK", sort: "LAST_REPLY", observation: UUID())
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -36, y: 1, rightToLeft: false, now: 0)
    #expect(trace.finish(gesture: gesture1, context: .init(scope: source.scope, current: source), x: -36, y: 1, now: 0.01) == nil)
    var scope = source; scope.observation = nil
    var newPager = source; newPager.observation = UUID()
    trace.synchronize(.init(scope: scope, current: newPager))
    #expect(trace.presentation(board: source.board, now: 0.02) == nil)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: .init(scope: source.scope, current: source), x: -76, y: 1, rightToLeft: false, now: 0.03)
    #expect(trace.finish(gesture: gesture2, context: .init(scope: source.scope, current: source), x: -76, y: 1, now: 0.04) == "life")
    scope.board = "life"; newPager.board = "life"
    trace.synchronize(.init(scope: scope, current: nil))
    trace.synchronize(.init(scope: scope, current: newPager))
    #expect(trace.presentation(board: "life", now: 0.05) != nil)
    scope.site = "DEEPNODE"
    trace.synchronize(.init(scope: scope, current: nil))
    #expect(trace.presentation(board: "life", now: 0.06) == nil)
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

@Test func homeBoardRegrabUnwindsDisplacementAtBothRailEndsInEitherLayoutDirection() throws {
    for rtl in [false, true] {
        for board in ["", "tech"] {
            let owner = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: board,
                orderedBoards: ["", "tech"], isHomeRoot: true)
            let context = ContentFeedBoardSwipeContext(scope: owner.scope, current: owner)
            let inward: CGFloat = (board.isEmpty != rtl) ? -1 : 1
            var trace = ContentFeedBoardSwipeTrace()
            let first = UUID()
            trace.begin(gesture: first, context: context, x: 55 * inward, y: 0, rightToLeft: rtl, now: 0)
            #expect(trace.finish(gesture: first, context: context, x: 55 * inward, y: 0, now: 0.01) == nil)
            let inFlight = try #require(trace.presentation(board: board, now: 0.05))

            let second = UUID()
            trace.begin(gesture: second, context: context, x: -12 * inward, y: 0, rightToLeft: rtl, now: 0.05)
            #expect(trace.presentation(board: board, now: 0.05) == inFlight)
            trace.change(gesture: second, context: context, x: -20 * inward, y: 0)
            let reversed = try #require(trace.presentation(board: board, now: 0.06))
            let neutral: CGFloat = board.isEmpty ? 0 : 1
            #expect(abs(reversed.offset) < abs(inFlight.offset))
            #expect(abs(reversed.boardPosition - neutral) < abs(inFlight.boardPosition - neutral))
            trace.change(gesture: second, context: context, x: -130 * inward, y: 0)
            #expect(trace.presentation(board: board, now: 0.07) == .init(offset: 0, boardPosition: neutral))
            #expect(trace.finish(gesture: second, context: context, x: -130 * inward, y: 0, now: 0.07) == nil)
        }
    }
}

@Test func homeBoardReleaseUsesRebasedTravelForThresholdDominanceAndFinalFrame() throws {
    let owner = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true)
    let context = ContentFeedBoardSwipeContext(scope: owner.scope, current: owner)
    for (start, end, expected) in [(CGPoint(x: 22, y: 4), CGPoint(x: 74, y: 4), nil),
                                  (CGPoint(x: 42, y: 28), CGPoint(x: 118, y: 68), ""),
                                  (CGPoint(x: 72, y: 0), CGPoint(x: 150, y: 70), nil)] as [(CGPoint, CGPoint, String?)] {
        var trace = ContentFeedBoardSwipeTrace()
        let first = UUID()
        trace.begin(gesture: first, context: context, x: -40, y: 1, rightToLeft: false, now: 0)
        trace.cancel(gesture: first, now: 0.01)
        let next = UUID()
        trace.begin(gesture: next, context: context, x: start.x, y: start.y, rightToLeft: false, now: 0.05)
        var expectedFrame = trace
        expectedFrame.change(gesture: next, context: context, x: end.x, y: end.y)
        let finalPose = try #require(expectedFrame.presentation(board: owner.board, now: 0.06))
        #expect(trace.finish(gesture: next, context: context, x: end.x, y: end.y, now: 0.06) == expected)
        #expect(trace.presentation(board: expected ?? owner.board, now: 0.06) == finalPose)
    }
}

@Test func homeBoardTapRetargetsFromDisplayedPoseAndRevokesTheHeldTouch() throws {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "",
        orderedBoards: ["", "tech", "life", "news"], isHomeRoot: true)
    var trace = ContentFeedBoardSwipeTrace()
    trace.tap(scope: source.scope, target: "tech", now: 0)
    #expect(trace.presentation(board: "tech", now: 0) == .init(offset: 0, boardPosition: 0))
    let tech = source.selecting("tech")
    let inFlight = try #require(trace.presentation(board: "tech", now: 0.05))
    trace.tap(scope: tech.scope, target: "news", now: 0.05)
    #expect(trace.presentation(board: "news", now: 0.05) == inFlight)
    let retargeted = try #require(trace.presentation(board: "news", now: 0.08))
    #expect(retargeted.boardPosition > inFlight.boardPosition)

    let news = source.selecting("news")
    let context = ContentFeedBoardSwipeContext(scope: news.scope, current: news)
    let gesture = UUID()
    trace.begin(gesture: gesture, context: context, x: 15, y: 0, rightToLeft: false, now: 0.08)
    let held = try #require(trace.presentation(board: "news", now: 0.08))
    trace.tap(scope: news.scope, target: "life", now: 0.09)
    #expect(trace.finish(gesture: gesture, context: context, x: 150, y: 0, now: 0.09) == nil)
    #expect(trace.presentation(board: "life", now: 0.09) == held)
    trace.tap(scope: source.selecting("life").scope, target: "tech", now: 0.1, animated: false)
    #expect(trace.settleID == nil)
}

@Test func homeBoardMatchingHandoffRegrabsVisuallyButCannotGainCommitRights() throws {
    let source = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true, site: "NODESEEK", sort: "LAST_REPLY", observation: UUID())
    var destination = source.selecting("life"); destination.observation = UUID()
    let start = ContentFeedBoardSwipeContext(scope: source.scope, current: source)
    let pending = ContentFeedBoardSwipeContext(scope: destination.scope, current: nil)
    let installed = ContentFeedBoardSwipeContext(scope: destination.scope, current: destination)
    var trace = ContentFeedBoardSwipeTrace()
    let first = UUID()
    trace.begin(gesture: first, context: start, x: -82, y: 0, rightToLeft: false, now: 0)
    #expect(trace.finish(gesture: first, context: start, x: -82, y: 0, now: 0.01) == destination.board)
    trace.synchronize(pending)
    let inFlight = try #require(trace.presentation(board: destination.board, now: 0.05))

    for unrelated in [ContentFeedBoardSwipeOwner(generation: 5, identityEpoch: "a", board: destination.board,
        orderedBoards: destination.orderedBoards, isHomeRoot: true, site: "NODESEEK", sort: "LAST_REPLY"),
        ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: destination.board,
        orderedBoards: destination.orderedBoards, isHomeRoot: false, site: "NODESEEK", sort: "LAST_REPLY")] {
        var blocked = trace
        let wrong = UUID()
        blocked.begin(gesture: wrong, context: .init(scope: unrelated, current: nil), x: 12, y: 0,
                      rightToLeft: false, now: 0.05)
        #expect(blocked.settleID == trace.settleID)
        #expect(blocked.finish(gesture: wrong, context: installed, x: 120, y: 0, now: 0.06) == nil)
    }
    let second = UUID()
    trace.begin(gesture: second, context: pending, x: 12, y: 0, rightToLeft: false, now: 0.05)
    #expect(trace.presentation(board: destination.board, now: 0.05) == inFlight)
    #expect(trace.settleID == nil)
    trace.synchronize(installed)
    trace.change(gesture: second, context: installed, x: 48, y: 0)
    let held = try #require(trace.presentation(board: destination.board, now: 0.06))
    #expect(held.boardPosition < inFlight.boardPosition)
    #expect(trace.finish(gesture: second, context: installed, x: 120, y: 0, now: 0.07) == nil)
    #expect(trace.presentation(board: destination.board, now: 0.07) != nil)

    let third = UUID()
    trace.begin(gesture: third, context: installed, x: 12, y: 0, rightToLeft: false, now: 0.08)
    #expect(trace.finish(gesture: third, context: installed, x: 120, y: 0, now: 0.09) == source.board)
}

@Test func homeBoardIgnoresStaleAndDuplicateRecognizerCallbacks() throws {
    let owner = ContentFeedBoardSwipeOwner(generation: 4, identityEpoch: "a", board: "tech",
        orderedBoards: ["", "tech", "life"], isHomeRoot: true, observation: UUID())
    let context = ContentFeedBoardSwipeContext(scope: owner.scope, current: owner)
    var trace = ContentFeedBoardSwipeTrace()
    let first = UUID()
    trace.begin(gesture: first, context: context, x: -20, y: 0, rightToLeft: false, now: 0)
    trace.cancel(gesture: first, now: 0.01)
    let oldSettle = try #require(trace.settleID)
    let second = UUID()
    trace.begin(gesture: second, context: context, x: -12, y: 0, rightToLeft: false, now: 0.04)
    let held = try #require(trace.presentation(board: owner.board, now: 0.04))
    trace.change(gesture: first, context: context, x: 140, y: 0)
    trace.cancel(gesture: first, now: 0.05)
    trace.complete(oldSettle)
    #expect(trace.finish(gesture: first, context: context, x: 140, y: 0, now: 0.05) == nil)
    #expect(trace.presentation(board: owner.board, now: 0.05) == held)
    #expect(trace.finish(gesture: second, context: context, x: -110, y: 0, now: 0.06) == "life")
    #expect(trace.finish(gesture: second, context: context, x: -110, y: 0, now: 0.06) == nil)
}

@Test func previewBlockedBodyNeverExposesCachedNodes() {
    let thread: JSONValue = .object(["postId": .integer(42), "title": .string("Title"),
        "body": .object(["isBlocked": .bool(true), "nodes": .array([.object(["type": .string("p")])])])])
    let content = ContentPostPreviewContent(postID: 42, summary: .null, thread: thread)
    #expect(content.isBlocked)
    #expect(content.nodes.isEmpty)
    #expect(!content.hasBody)
}
