import Foundation
import Testing
import NodysseyNativeCore
@testable import Sharing

func content(_ nodes: [NativeRichNode], floor: String = "#12") throws -> JSONValue {
    .object([
        "authorName": .string("Alice / 爱丽丝"), "floor": .string(floor),
        "createdAtTitle": .string("2026-11-14 09:30"),
        "nodes": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(nodes)),
        "signatureNodes": try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode([NativeRichNode.paragraph([.text("NOT PART OF THE FLOOR", .init())])]))
    ])
}

@Test func realFloorSnapshotPreservesAttributionAndExcludesSignature() throws {
    let value = try content([.paragraph([.text("An actual reply 👩🏽‍💻", .init())])])
    let document = try FloorShareDocument.make(
        context: .init(content: value, threadTitle: "Thread title"),
        postID: 9_007_199_254_740_993, page: 2, floor: "#12", origin: "https://forum.example",
        language: .english)
    #expect(document.author == "Alice / 爱丽丝")
    #expect(document.floor == "#12")
    #expect(document.title == "Thread title")
    #expect(document.source.absoluteString == "https://forum.example/post-9007199254740993-2#12")
    #expect(document.body == "An actual reply 👩🏽‍💻")
    #expect(!document.body.contains("NOT PART"))
    #expect(!document.truncated)
}
