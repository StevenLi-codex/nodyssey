import Foundation
import Testing
@testable import NativeRendering

@Test func encodesRequiredNullableFieldsForKotlinReaders() throws {
    for node in [NativeRichNode.image(url: "https://example.org/a", alt: nil), .code(.init(code: "a"))] {
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        let key = json["type"] as? String == "img" ? "alt" : "language"
        #expect(json[key] is NSNull)
    }
    for node in [NativeInlineNode.image(url: "https://example.org/a", alt: nil), .sticker(url: "https://example.org/s", alt: nil)] {
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        #expect(json["alt"] is NSNull)
    }
}

@Test func defaultStardustAndAnsiFieldsMatchOmittedKotlinDefaults() throws {
    let receive = try JSONDecoder().decode(NativeRichNode.self, from: Data(#"{"type":"stardust","memberId":7,"refId":19,"amount":4}"#.utf8))
    #expect(receive == .stardust(.init(memberId: 7, refId: 19, amount: 4)))
    let span = try JSONDecoder().decode(NativeAnsiSpan.self, from: Data(#"{"start":0,"end":2}"#.utf8))
    #expect(span == .init(start: 0, end: 2))
}
