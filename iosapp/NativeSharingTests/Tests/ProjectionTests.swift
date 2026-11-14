import Foundation
import Testing
import NodysseyNativeCore
@testable import Sharing

private func document(_ nodes: [NativeRichNode]) throws -> FloorShareDocument {
    try FloorShareDocument.make(context: .init(content: content(nodes), threadTitle: "Thread"), postID: 17, page: 2, floor: "#12", origin: "https://forum.example", language: .english)
}

@Test func textFirstProjectionKeepsStructureWithoutFetchingOrExposingMediaURLs() throws {
    let value = try document([
        .heading(level: 2, inlines: [.text("Heading", .init(bold: true))]),
        .paragraph([.link("Link label", "https://private.example/token", .init()), .lineBreak,
                    .quoteRef(name: "Bob", floor: "#3", url: "/post-17-1#3"),
                    .image(url: "https://private.example/secret", alt: "A chart")]),
        .quote([.paragraph([.text("Quoted text", .init())])]),
        .code(.init(code: "print(42)")),
        .list(ordered: true, items: [[.paragraph([.text("First", .init())])]]),
        .table(cells: [[[.text("Cell", .init())]]]),
        .vote(voteId: 3), .image(url: "https://private.example/second", alt: nil)
    ])
    for text in ["Heading", "Link label", "Bob #3", "Quoted text", "print(42)", "1. First", "Cell", "[Image omitted]", "[Poll omitted]"] {
        #expect(value.body.contains(text))
    }
    #expect(!value.body.contains("private.example"))
}

@Test func closedFoldsAndInactiveTabsAreNotAccidentallyDisclosed() throws {
    let value = try document([
        .fold(title: "Spoiler", children: [.paragraph([.text("HIDDEN CONTENT", .init())])], open: false),
        .tabs([.init(title: "First tab", children: [.paragraph([.text("Visible tab", .init())])]),
               .init(title: "Second tab", children: [.paragraph([.text("INACTIVE CONTENT", .init())])])])
    ])
    #expect(value.body.contains("Spoiler"))
    #expect(value.body.contains("[Collapsed content omitted]"))
    #expect(value.body.contains("Visible tab"))
    #expect(value.body.contains("[Other tabs omitted]"))
    #expect(!value.body.contains("HIDDEN CONTENT"))
    #expect(!value.body.contains("INACTIVE CONTENT"))
}

@Test func oversizedBodyIsBoundedAndDisclosedWithoutBreakingGraphemes() throws {
    let value = try document([.paragraph([.text(String(repeating: "👩🏽‍💻", count: 8000), .init())])])
    #expect(value.truncated)
    #expect(value.body.count <= 6000)
    #expect(value.body.last == "👩🏽‍💻")
    let manyLines = try document([.code(.init(code: String(repeating: "short\n", count: 2000)))])
    #expect(manyLines.truncated)
    #expect(manyLines.body.components(separatedBy: "\n").count <= 100)
}

@Test func wrongFloorBlockedOrMalformedSnapshotCannotBecomeAnImage() throws {
    let dto = try content([.paragraph([.text("body", .init())])])
    #expect(throws: FloorShareError.invalidContent) {
        try FloorShareDocument.make(context: .init(content: dto, threadTitle: "Thread"), postID: 17, page: 2, floor: "#13", origin: "https://forum.example", language: .english)
    }
    var fields = try #require(dto.object)
    fields["isBlocked"] = .bool(true)
    #expect(throws: FloorShareError.blockedContent) {
        try FloorShareDocument.make(context: .init(content: .object(fields), threadTitle: "Thread"), postID: 17, page: 2, floor: "#12", origin: "https://forum.example", language: .english)
    }
    fields["isBlocked"] = .bool(false)
    fields["nodes"] = .array([.object(["type": .string("future-node")])])
    #expect(throws: FloorShareError.invalidContent) {
        try FloorShareDocument.make(context: .init(content: .object(fields), threadTitle: "Thread"), postID: 17, page: 2, floor: "#12", origin: "https://forum.example", language: .english)
    }
}

@Test func sourceRejectsCredentialedURLsAndRetainsURLOnlyPageSemantics() throws {
    #expect(throws: FloorShareError.invalidSource) { try FloorShareDocument.sourceURL(origin: "https://user:secret@example.com", postID: 1, page: 1, floor: nil) }
    let url = try FloorShareDocument.sourceURL(origin: "https://forum.example/old?tracking=1#old", postID: 17, page: 0, floor: "12")
    #expect(url.absoluteString == "https://forum.example/post-17-1#12")
}
