import Foundation
import Testing
@testable import NativeRendering

@MainActor
@Test func projectionReuseIsExactAndRetainsOnlyTheCurrentInput() throws {
    // A recycled row must never show an old payload or account's projection.
    let owner = NSObject()
    typealias Key = NativeRenderingInput<String>
    func key(_ generation: Int, _ content: String, epoch: String = "A", app: NSObject? = nil) -> Key {
        Key(app: ObjectIdentifier(app ?? owner), generation: generation, identityEpoch: epoch, content: content)
    }
    let memo = NativeRenderingMemo<Key, Result<[NativeRichNode], Error>>()
    var decodes = 0
    func read(_ key: Key) -> Result<[NativeRichNode], Error> {
        memo.value(for: key) {
            decodes += 1
            return Result { try JSONDecoder().decode([NativeRichNode].self, from: Data(key.content.utf8)) }
        }
    }
    let first = key(0, #"[{"type":"vote","voteId":9007199254740993}]"#)
    #expect(try read(first).get() == [.vote(voteId: 9_007_199_254_740_993)])
    _ = read(first)
    #expect(decodes == 1)
    let replacement = key(0, ##"[{"type":"p","inlines":[{"type":"a","text":"new","url":"#2"}]}]"##)
    #expect(try read(replacement).get() == [.paragraph([.link("new", "#2", .init())])])
    #expect(decodes == 2)
    _ = read(key(1, replacement.content))
    #expect(decodes == 3)
    // The bounded one-entry cache evicts old inputs, not a second content store.
    _ = read(first)
    #expect(decodes == 4)
    let bad = key(0, "invalid")
    #expect(throws: (any Error).self) { try read(bad).get() }
    _ = read(bad)
    #expect(decodes == 5)
    #expect(try read(first).get() == [.vote(voteId: 9_007_199_254_740_993)])
    #expect(decodes == 6)
    _ = read(key(0, first.content, epoch: "B"))
    #expect(decodes == 7)
    let otherOwner = NSObject()
    _ = read(key(0, first.content, epoch: "B", app: otherOwner))
    #expect(decodes == 8)
}
