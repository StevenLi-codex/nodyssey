import Foundation
import Testing
@testable import NativeRendering

@Test func promotesLegacyRowsOnlyWhenCanonicalCellsAreEmpty() throws {
    // Verbatim fixture from PostDetailCacheTest.kt, `reads a table cached as plain strings`.
    let stored = #"{"type":"table","rows":[["节点","延迟"],["东京","48ms"]]}"#
    let node = try JSONDecoder().decode(NativeRichNode.self, from: Data(stored.utf8))
    #expect(node == .table(cells: [
        [[.text("节点", .init())], [.text("延迟", .init())]],
        [[.text("东京", .init())], [.text("48ms", .init())]],
    ]))
    let both = #"{"type":"table","cells":[[[{"type":"a","text":"new","url":"https://example.org"}]]],"rows":[["old"]]}"#
    #expect(try JSONDecoder().decode(NativeRichNode.self, from: Data(both.utf8)) == .table(cells: [[[.link("new", "https://example.org", .init())]]]))
    let empty = #"{"type":"table","cells":[],"rows":[["old"]]}"#
    #expect(try JSONDecoder().decode(NativeRichNode.self, from: Data(empty.utf8)) == .table(cells: [[[.text("old", .init())]]]))
}

@Test func repositoryDiscriminatorFixtureRetainsKotlinDefaults() throws {
    // Verbatim stored JSON from PostDetailCacheTest.kt, `every node discriminator still decodes`.
    let stored = #"""
    [
      {"type":"p","inlines":[{"type":"t","text":"x"},{"type":"a","text":"y","url":"https://example.invalid"},
        {"type":"sticker","url":"https://example.invalid/s.png","alt":null},
        {"type":"iimg","url":"https://example.invalid/c.png","alt":null},
        {"type":"qref","name":"n","floor":"#3","url":"https://example.invalid/p-1"},{"type":"br"}]},
      {"type":"h","level":2,"inlines":[]},
      {"type":"img","url":"https://example.invalid/i.png","alt":null},
      {"type":"vote","voteId":2871},
      {"type":"code","code":"ls","language":"sh"},
      {"type":"quote","children":[]},
      {"type":"tabs","tabs":[{"title":"t","children":[]}]},
      {"type":"fold","title":"t","children":[]},
      {"type":"list","ordered":true,"items":[]},
      {"type":"table"},
      {"type":"hr"}
    ]
    """#
    let nodes = try JSONDecoder().decode([NativeRichNode].self, from: Data(stored.utf8))
    #expect(nodes.count == 11)
    #expect(nodes[0] == .paragraph([.text("x", .init()), .link("y", "https://example.invalid", .init()), .sticker(url: "https://example.invalid/s.png", alt: nil), .image(url: "https://example.invalid/c.png", alt: nil), .quoteRef(name: "n", floor: "#3", url: "https://example.invalid/p-1"), .lineBreak]))
    #expect(nodes[4] == .code(.init(code: "ls", language: "sh")))
    #expect(nodes[7] == .fold(title: "t", children: [], open: false))
    #expect(nodes[9] == .table(cells: []))
}

@Test func requiredIdentitiesAndUnknownDiscriminatorsAreNotSilentlyLost() {
    for json in [#"{"type":"vote"}"#, #"{"type":"vote","voteId":1.5}"#, #"{"type":"vote","voteId":9223372036854775808}"#, #"{"type":"future"}"#, #"{"type":"p","inlines":[{"type":"future"}]}"#] {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(NativeRichNode.self, from: Data(json.utf8))
        }
    }
}
