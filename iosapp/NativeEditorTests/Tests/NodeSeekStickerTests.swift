import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

@Test func untouchedOrObsoleteToolbarKeepsStickerEntryAndCustomOrderSurvives() {
    let postAndReply = ["IMAGE", "HOSTED_IMAGE", "EMOJI", "MENTION", "BOLD", "LINK", "QUOTE", "CODE", "LIST", "HEADING", "STRIKETHROUGH", "ITALIC"]
    let message = ["BOLD", "CODE", "LINK", "HOSTED_IMAGE", "EMOJI"]
    for surface in ["POST", "REPLY", "MESSAGE"] {
        let expected = surface == "MESSAGE" ? message : postAndReply
        #expect(EditorToolbarLayout.actions([], surface: surface) == expected)
        #expect(EditorToolbarLayout.actions(["REMOVED"], surface: surface) == expected)
        #expect(EditorToolbarLayout.actions(nil, surface: surface) == expected)
        #expect(EditorToolbarLayout.actions(["LINK", "REMOVED", "BOLD", "LINK"], surface: surface) == ["LINK", "BOLD"])
        // Deliberately hiding EMOJI in a nonempty custom layout must stay respected.
        #expect(EditorToolbarLayout.actions(["BOLD"], surface: surface) == ["BOLD"])
    }
}

@Test func deletingFinalToolbarActionKeepsCustomLayoutOnReopen() {
    let arrangements = [["BOLD"], ["LINK", "CODE", "BOLD"]]
    for surface in ["POST", "REPLY", "MESSAGE"] {
        for arrangement in arrangements {
            let remaining = EditorToolbarLayout.removing(IndexSet(integersIn: arrangement.indices), from: arrangement)
            #expect(remaining == arrangement)
            #expect(EditorToolbarLayout.actions(remaining, surface: surface) == arrangement)
        }
    }
}

@Test func validToolbarDeletionPreservesSurvivingOrderAndExplicitlyHiddenEmoji() {
    let arrangement = ["LINK", "EMOJI", "CODE", "BOLD"]
    let remaining = EditorToolbarLayout.removing(IndexSet([1, 2]), from: arrangement)
    #expect(remaining == ["LINK", "BOLD"])
    for surface in ["POST", "REPLY", "MESSAGE"] {
        #expect(EditorToolbarLayout.actions(remaining, surface: surface) == ["LINK", "BOLD"])
    }
    #expect(EditorToolbarLayout.removing(IndexSet(), from: arrangement) == arrangement)
    #expect(EditorToolbarLayout.removing(IndexSet(integersIn: 0..<3), from: arrangement) == ["BOLD"])
}

@Test @MainActor func nativeStickerSelectionReplacesUTF16SelectionAndPublishesShortcodesNotImages() async throws {
    let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"mine":[{"url":"https://e.test/personal.gif","name":"saved"}],"subscriptions":[],"groupLayout":{"hidden":["site:yct"]},
     "arrangedGroupKeys":["mine","site:xhj","site:ac","site:yct","fluent"],
     "siteGroups":[
      {"key":"site:ac","entries":[{"type":"Sticker","name":"ac01","shortcode":" :ac01: ","url":"https://www.nodeseek.com/static/image/sticker/ac/01.png"}]},
      {"key":"site:yct","entries":[{"type":"Sticker","name":"yct001","shortcode":" :yct001: ","url":"https://www.nodeseek.com/static/image/sticker/yct/001.gif"}]},
      {"key":"site:xhj","entries":[{"type":"Sticker","name":"xhj004","shortcode":" :xhj004: ","url":"https://www.nodeseek.com/static/image/sticker/xhj/004.gif"}]},
      {"key":"fluent","entries":[{"type":"Unicode","character":"😀"}]}]}
    """#.utf8))
    let groups = MediaStickerGroup.groups(snapshot)
    #expect(groups.map(\.id) == ["mine", "site:xhj", "site:ac", "site:yct", "fluent"])
    #expect(groups.filter { !$0.hidden }.map(\.id) == ["mine", "site:xhj", "site:ac", "fluent"])
    let initialPicker = MediaStickerPickerContent(snapshot: snapshot, selectedKey: "mine")
    #expect(initialPicker.groups.map(\.id) == ["site:xhj", "site:ac", "fluent"])
    #expect(initialPicker.selectionKey == "site:xhj")
    #expect(groups.first { $0.id == "mine" }?.entries.map(\.id) == ["https://e.test/personal.gif"])
    // Re-enable YCT through the same observed snapshot shape before selecting it.
    var visibleSnapshot = try #require(snapshot.object)
    visibleSnapshot["groupLayout"] = .object(["hidden": .array([])])
    let transport = RecordingTransport()
    let model = EditorViewModel(mode: .reply(postID: 42), transport: transport,
        arguments: ["quotedFloor": .integer(7), "replyToAuthor": .string("reader")])
    let original = "前😀替换后"
    model.session.changeBody(EditorBuffer(text: original, selection: (original as NSString).range(of: "替换")))
    var picker = MediaStickerInteraction(mode: .picker)
    for id in ["site:ac", "site:yct", "site:xhj"] {
        let content = MediaStickerPickerContent(snapshot: .object(visibleSnapshot), selectedKey: id)
        #expect(content.selectionKey == id)
        let sticker = try #require(content.entries.first)
        guard case .insert(let value) = picker.activate(sticker) else { Issue.record("Picker did not insert"); return }
        model.insert(value)
    }
    let body = "前😀 :ac01:  :yct001:  :xhj004: 后"
    #expect(model.session.body.text == body)
    #expect(model.session.body.selection == NSRange(location: (body as NSString).range(of: "后").location, length: 0))
    #expect(model.attachments.isEmpty)
    _ = try await model.session.submit()
    let calls = await transport.calls
    let save = try #require(calls.first { $0.0 == "draft.comment.save" })
    let send = try #require(calls.first { $0.0 == "editor.comment.publish" })
    #expect(save.1["body"] == .string(body))
    #expect(send.1 == ["postId": .integer(42), "quotedFloor": .integer(7), "body": .string("@reader [#7](/post-42-1#7) " + body)])
    #expect(!calls.contains { $0.0.contains("upload") })
    model.invalidate()
}

@Test @MainActor func nativeStickerPreviewDecodesCanonicalInlineStickerRatherThanMarkdownImage() async throws {
    let transport = StickerPreviewFixture()
    let model = EditorViewModel(mode: .reply(postID: 42), transport: transport, arguments: [:])
    model.insert(" :ac01:  :yct001:  :xhj004: ")
    await model.showPreview()
    let nodes = try #require(model.preview)
    guard case .paragraph(let inlines) = try #require(nodes.first) else { Issue.record("Expected paragraph"); return }
    #expect(inlines == [
        .sticker(url: "https://www.nodeseek.com/static/image/sticker/ac/01.png", alt: "ac01"),
        .sticker(url: "https://www.nodeseek.com/static/image/sticker/yct/001.gif", alt: "yct001"),
        .sticker(url: "https://www.nodeseek.com/static/image/sticker/xhj/004.gif", alt: "xhj004")])
    #expect(await transport.calls.map(\.0) == ["editor.preview"])
    #expect(await transport.calls.first?.1["body"] == .string(" :ac01:  :yct001:  :xhj004: "))
    model.invalidate()
}

// Canonical bridge response fixture, not a substitute Markdown parser or live website.
private actor StickerPreviewFixture: NativeTransport {
    var calls: [(String, [String: JSONValue])] = []
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((operation, arguments))
        guard operation == "editor.preview" else { throw NativeFailure(code: "UNEXPECTED", message: "No writes allowed") }
        return try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        [{"type":"p","inlines":[
          {"type":"sticker","url":"https://www.nodeseek.com/static/image/sticker/ac/01.png","alt":"ac01"},
          {"type":"sticker","url":"https://www.nodeseek.com/static/image/sticker/yct/001.gif","alt":"yct001"},
          {"type":"sticker","url":"https://www.nodeseek.com/static/image/sticker/xhj/004.gif","alt":"xhj004"}]}]
        """#.utf8))
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}
