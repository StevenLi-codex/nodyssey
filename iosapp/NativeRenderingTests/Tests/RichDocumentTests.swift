import Foundation
import Testing
@testable import NativeRendering

// Synthetic canonical cache fixtures: no authenticated or live forum data.
private func decode(_ json: String) throws -> NativeRichNode {
    try JSONDecoder().decode(NativeRichNode.self, from: Data(json.utf8))
}

@Test func paragraphUsesCanonicalInlineTagsAndDefaultStyles() throws {
    let node = try decode(#"{"type":"p","inlines":[{"type":"t","text":"你好 👩🏽‍💻"},{"type":"a","text":"site","url":"https://example.org","style":{"bold":true,"italic":true,"strikethrough":true,"code":true}}]}"#)
    guard case .paragraph(let inlines) = node else { Issue.record("Not a paragraph"); return }
    #expect(inlines == [
        .text("你好 👩🏽‍💻", NativeInlineStyle()),
        .link("site", "https://example.org", NativeInlineStyle(bold: true, italic: true, strikethrough: true, code: true)),
    ])
    #expect(try JSONDecoder().decode(NativeRichNode.self, from: JSONEncoder().encode(node)) == node)
}
