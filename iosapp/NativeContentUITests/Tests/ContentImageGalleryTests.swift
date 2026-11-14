import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test func galleryCallbackOpensClickedStickerInsteadOfUnrelatedImage() throws {
    let body = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"type":"img","url":"imageA"},{"type":"p","inlines":[{"type":"sticker","url":"stickerS"}]}]"#.utf8))
    var route: String?
    var args: [String: JSONValue] = [:]
    let callback = ContentImageGallery.onImage(value: body) { route = $0; args = $1 }
    callback("stickerS", nil)
    #expect(route == "ImageViewer")
    let urls = try #require(args["urls"]?.array)
    let index = try #require(args["index"]?.int)
    #expect(urls[Int(index)] == .string("stickerS"))
    #expect(urls == [.string("stickerS")])
    callback("imageA", nil)
    #expect(args["urls"] == .array([.string("imageA")]))
    #expect(args["index"] == .integer(0))
}

@Test func galleryCallbackKeepsNestedImageOrderAndDeduplicates() throws {
    let body = try JSONDecoder().decode(JSONValue.self, from: Data(#"[{"type":"img","url":"A"},{"type":"fold","children":[{"type":"p","inlines":[{"type":"iimg","url":"B"},{"type":"iimg","url":"A"}]}]}]"#.utf8))
    var args: [String: JSONValue] = [:]
    ContentImageGallery.onImage(value: body) { _, value in args = value }("B", nil)
    #expect(args["urls"] == .array([.string("A"), .string("B")]))
    #expect(args["index"] == .integer(1))
}
