import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test func floorOverridesPageAndResumeClampsDeletedPages() {
    #expect(ContentReadingTarget(floor: "#127", page: 2).page == 13)
    #expect(ContentReadingTarget(floor: "#0", page: 3).page == 1)
    #expect(ContentReadingTarget(floor: "#2147483648", page: 3).page == 3)
    #expect(ContentReadingTarget(floor: "invalid", page: 3).page == 3)
    #expect(ContentReadingTarget(floor: "#127", page: 13).clamped(to: 4) == ContentReadingTarget(floor: nil, page: 4))
}

@Test func ordinaryOpeningShowsBodyAndPreservesUnreadMarkerAndExplicitTargets() {
    let fresh: JSONValue = .object(["isThreadFresh": .bool(true), "seenRepliesIfUnread": .integer(20), "firstLoadedPage": .integer(1), "lastLoadedPage": .integer(5)])
    let unread = ContentThreadOpening(floor: nil, page: nil, status: fresh)
    #expect(unread.target == ContentReadingTarget(floor: "#0", page: nil))
    #expect(unread.firstNewFloor == 21)
    #expect(ContentThreadOpening(floor: "#21", page: nil, status: fresh).target.page == 3)
    #expect(unread.needsLoad)
    let named = ContentThreadOpening(floor: nil, page: 2, status: fresh)
    #expect(named.target.page == 2)
    #expect(named.target.floor == nil)
    let cached: JSONValue = .object(["isThreadFresh": .bool(true), "seenRepliesIfUnread": .null, "firstLoadedPage": .integer(4), "lastLoadedPage": .integer(5)])
    #expect(!ContentThreadOpening(floor: nil, page: 4, status: cached).needsLoad)
    #expect(ContentThreadOpening(floor: nil, page: 3, status: cached).needsLoad)
}

@Test func feedRestorationSeparatesBoardAndSortAndKeepsActualPage() {
    var memory = ContentFeedMemory()
    memory.record(board: "tech", sort: "LAST_REPLY", postID: 9007199254740993, page: 9)
    #expect(memory.position(board: "tech", sort: "LAST_REPLY")?.page == 9)
    #expect(memory.position(board: "tech", sort: "LAST_REPLY")?.postID == 9007199254740993)
    #expect(memory.position(board: "tech", sort: "POST_TIME") == nil)
    #expect(memory.position(board: "life", sort: "LAST_REPLY") == nil)
    memory.record(board: "tech", sort: "LAST_REPLY", postID: 9007199254740994, page: nil)
    #expect(memory.position(board: "tech", sort: "LAST_REPLY")?.page == 9)
}

@Test func quoteContextKeepsNestedTextWithoutReconstructingMarkdown() {
    let nodes: JSONValue = .array([
        .object(["type": .string("p"), "inlines": .array([.object(["type": .string("t"), "text": .string("hello ")]), .object(["type": .string("a"), "text": .string("member"), "url": .string("/space/1")])])]),
        .object(["type": .string("fold"), "children": .array([.object(["type": .string("code"), "code": .string("print(1)")])])])])
    #expect(ContentQuoteContext.text(nodes) == "hello member")
}

@Test func moneyReactionsRequireConfirmationAndCannotRepeat() {
    #expect(ContentReactionPolicy.decision(action: "Upvote", signedIn: false, spent: false) == .signIn)
    #expect(ContentReactionPolicy.decision(action: "Upvote", signedIn: true, spent: false) == .send)
    #expect(ContentReactionPolicy.decision(action: "ChickenLeg", signedIn: true, spent: false) == .confirm)
    #expect(ContentReactionPolicy.decision(action: "Dislike", signedIn: true, spent: false) == .confirm)
    #expect(ContentReactionPolicy.decision(action: "ChickenLeg", signedIn: true, spent: true) == .disabled)
}

@Test func mergedReadKeepsBothNullableSources() throws {
    let sources: JSONValue = .array([
        .object(["category": .string("REPLIES"), "viewedId": .integer(9007199254740993), "isUnread": .bool(true)]),
        .object(["category": .string("MENTIONS"), "viewedId": .null, "isUnread": .bool(true)])])
    #expect(try ContentNotificationAction.readArguments(.object(["sources": sources]))["sources"] == sources)
}

@Test func pollSelectionHonorsSingleMultipleAndServerState() {
    var selection = ContentPollSelection()
    selection.toggle(1, multiple: false)
    selection.toggle(2, multiple: false)
    #expect(selection.ids == [2])
    selection.toggle(3, multiple: true)
    #expect(selection.ids == [2, 3])
    selection.reconcile(allowed: [2], alreadyVoted: false, locked: false)
    #expect(selection.ids == [2])
    selection.reconcile(allowed: [2], alreadyVoted: true, locked: false)
    #expect(selection.ids.isEmpty)
}

@Test func pagingWindowUsesGlobalAccessAndExactIdentity() throws {
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"pagerId":"p","items":[{"summary":{"postId":9007199254740993},"page":9}],"placeholdersBefore":80,"placeholdersAfter":10,"itemCount":91}"#.utf8))
    let window = try ContentPagingWindow(json)
    #expect(window.rows[0].id == 9007199254740993)
    #expect(window.rows[0].globalIndex == 80)
    #expect(window.rows[0].page == 9)
    #expect(window.accessArguments(for: window.rows[0].id)?["index"] == .integer(80))
    #expect(try ContentPagingWindow(.null).rows.isEmpty)
}
