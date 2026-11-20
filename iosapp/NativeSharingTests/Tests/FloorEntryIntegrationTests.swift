import Foundation
import Testing
import NodysseyNativeCore
@testable import Sharing

// Runs the verbatim ContentPostDetail.floorActionSheet initializer against real ContentShareLink,
// FloorShareContext and document decoding. No SwiftUI environment/task or live I/O.
@MainActor private func imageDocument(_ entry: ContentShareLink) throws -> FloorShareDocument {
    let context = try #require(entry.shareContext)
    return try FloorShareDocument.make(context: context, postID: entry.postID, page: entry.page,
                                       floor: entry.floor, origin: "https://forum.example", language: .english)
}

@Test @MainActor func selectedFloorEntryUsesItsBodyTitleAndPageNotFirstLoadedReply() throws {
    let first = try content([.paragraph([.text("Unselected first reply", .init())])], floor: "#11")
    let selected = try content([.paragraph([.text("Selected reply body 👩🏽‍💻", .init())])], floor: "#32")
    let thread: JSONValue = .object([
        "title": .string("Exact loaded thread title"), "firstLoadedPage": .integer(2),
        "comments": .array([first, selected]), "commentPages": .array([.integer(2), .integer(4)])
    ])
    let entry = actualFloorEntry(value: selected, page: 4, opening: false,
                                postID: 9_007_199_254_740_993, threadValue: thread)
    let context = try #require(entry.shareContext)
    #expect(context.content == selected)
    #expect(!context.openingPost)
    #expect(!context.revealedBlocked)
    let document = try imageDocument(entry)
    #expect(document.body == "Selected reply body 👩🏽‍💻")
    #expect(document.title == "Exact loaded thread title")
    #expect(document.floor == "#32")
    #expect(document.source.absoluteString == "https://forum.example/post-9007199254740993-4#32")
    #expect(!document.body.contains("NOT PART OF THE FLOOR"))
}

@Test @MainActor func floorEntryBlockedRevealIsScopedToExactRowIdentity() throws {
    var fields = try #require(try content([.paragraph([.text("Blocked selected body", .init())])], floor: "#32").object)
    fields["isBlocked"] = .bool(true)
    let thread: JSONValue = .object(["title": .string("Thread")])
    for expanded: Set<String> in [[], ["floor:#11"]] {
        #expect(actualFloorBlocked(value: .object(fields), opening: false, expanded: expanded))
        let entry = actualFloorEntry(value: .object(fields), page: 4, opening: false,
                                    postID: 17, threadValue: thread, expanded: expanded)
        #expect(throws: FloorShareError.blockedContent) { try imageDocument(entry) }
    }
    #expect(!actualFloorBlocked(value: .object(fields), opening: false, expanded: ["floor:#32"]))
    let revealed = actualFloorEntry(value: .object(fields), page: 4, opening: false,
                                   postID: 17, threadValue: thread, expanded: ["floor:#32"])
    #expect(try imageDocument(revealed).body == "Blocked selected body")
}

@Test @MainActor func floorEntryRejectsMissingReplyFloorWrongFloorAndMissingTitle() throws {
    let dto = try content([.paragraph([.text("Selected body", .init())])], floor: "#32")
    let thread: JSONValue = .object(["title": .string("Thread")])
    var fields = try #require(dto.object)
    fields.removeValue(forKey: "floor")
    fields["commentId"] = .integer(321)
    let missing = actualFloorEntry(value: .object(fields), page: 4, opening: false,
                                  postID: 17, threadValue: thread)
    #expect(missing.floor == nil, "Never synthesize a reply floor from comment ID")
    #expect(throws: FloorShareError.missingContext) { try imageDocument(missing) }
    var wrong = actualFloorEntry(value: dto, page: 4, opening: false, postID: 17, threadValue: thread)
    wrong.floor = "#11"
    #expect(throws: FloorShareError.invalidContent) { try imageDocument(wrong) }
    let noTitle = actualFloorEntry(value: dto, page: 4, opening: false, postID: 17, threadValue: .null)
    #expect(throws: FloorShareError.missingContext) { try imageDocument(noTitle) }
}

@Test @MainActor func onlyOpeningEntryMaySupplyFloorZeroForNullableFloor() throws {
    var fields = try #require(try content([.paragraph([.text("Opening body", .init())])]).object)
    fields["floor"] = .null
    let entry = actualFloorEntry(value: .object(fields), page: 1, opening: true,
                                postID: 17, threadValue: .object(["title": .string("Opening title")]))
    #expect(entry.shareContext?.openingPost == true)
    #expect(entry.floor == "#0")
    let document = try imageDocument(entry)
    #expect(document.body == "Opening body")
    #expect(document.source.absoluteString == "https://forum.example/post-17-1#0")
}
