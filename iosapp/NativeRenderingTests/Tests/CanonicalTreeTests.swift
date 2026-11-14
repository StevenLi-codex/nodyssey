import Foundation
import Testing
@testable import NativeRendering

@Test func canonicalCacheTreeRetainsEveryVariantAndExactIdentities() throws {
    let json = #"""
    {"type":"quote","children":[
      {"type":"h","level":3,"inlines":[{"type":"t","text":"Heading"}]},
      {"type":"img","url":"https://example.org/image.png","alt":"Screenshot"},
      {"type":"vote","voteId":9007199254740993},
      {"type":"stardust","memberId":9223372036854775807,"refId":9007199254740995,"amount":42,"description":"A request","onetime":true},
      {"type":"code","code":"a😀中","language":"ansi","columns":5,"spans":[{"start":1,"end":4,"fg":10,"bg":0,"bold":true,"underline":true}]},
      {"type":"tabs","tabs":[{"title":"First","children":[{"type":"hr"}]},{"title":"Second","children":[{"type":"fold","title":"Details","open":true,"children":[{"type":"p","inlines":[{"type":"sticker","url":"https://example.org/sticker.png","alt":":smile:"},{"type":"iimg","url":"https://example.org/inline.png","alt":null},{"type":"qref","name":"alice","floor":"#3","url":"https://example.org/post/7#3"},{"type":"br"}]}]}]}]},
      {"type":"list","ordered":true,"items":[[{"type":"p","inlines":[{"type":"t","text":"One"}]}],[{"type":"quote","children":[{"type":"hr"}]}]]},
      {"type":"table","cells":[[[{"type":"a","text":"Clickable","url":"https://example.org","style":{"italic":true}}],[{"type":"iimg","url":"https://example.org/cell.png","alt":"cell"}]]]},
      {"type":"hr"}
    ]}
    """#
    let node = try JSONDecoder().decode(NativeRichNode.self, from: Data(json.utf8))
    let encoded = try JSONEncoder().encode(node)
    let result = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let children = try #require(result["children"] as? [[String: Any]])
    #expect(children.compactMap { $0["type"] as? String } == ["h", "img", "vote", "stardust", "code", "tabs", "list", "table", "hr"])
    #expect((children[2]["voteId"] as? NSNumber)?.int64Value == 9_007_199_254_740_993)
    #expect((children[3]["memberId"] as? NSNumber)?.int64Value == Int64.max)
    #expect((children[3]["refId"] as? NSNumber)?.int64Value == 9_007_199_254_740_995)
    #expect(children[3]["amount"] as? Int == 42)
    #expect(children[3]["description"] as? String == "A request")
    #expect(children[3]["onetime"] as? Bool == true)
    #expect(try JSONDecoder().decode(NativeRichNode.self, from: encoded) == node)
    // Compare every supplied field recursively; default fields may be materialized by encoding.
    func preserves(_ source: Any, _ target: Any) -> Bool {
        if let source = source as? [String: Any], let target = target as? [String: Any] {
            return source.allSatisfy { key, value in target[key].map { preserves(value, $0) } ?? (value is NSNull) }
        }
        if let source = source as? [Any], let target = target as? [Any] {
            return source.count == target.count && zip(source, target).allSatisfy { preserves($0, $1) }
        }
        return (source as? NSObject)?.isEqual(target) == true
    }
    #expect(preserves(try JSONSerialization.jsonObject(with: Data(json.utf8)), result))
}
