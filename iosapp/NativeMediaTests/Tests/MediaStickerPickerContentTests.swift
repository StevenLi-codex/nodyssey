import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeMedia

@Test func editorPickerExcludesPersonalCollectionWithoutChangingManagementCatalogue() throws {
    let snapshot = try pickerSnapshot()
    let content = MediaStickerPickerContent(snapshot: snapshot, selectedKey: nil)
    #expect(content.groups.map(\.id) == ["site:xhj", "gh:o/r/cats", "site:ac", "fluent"])
    #expect(content.selectionKey == "site:xhj")
    #expect(content.entries.map(\.insertion) == [" :xhj004: "])

    // Management still receives the collection and its original persisted identity/order.
    let catalogue = MediaStickerGroup.groups(snapshot)
    #expect(catalogue.map(\.id) == ["mine", "site:xhj", "gh:o/r/cats", "site:ac", "site:yct", "gh:o/r/hidden", "fluent"])
    let personal = try #require(catalogue.first { $0.id == "mine" })
    #expect(personal.entries.map(\.id) == ["https://e.test/personal.gif"])
    #expect(personal.entries.map(\.insertion) == ["![saved](https://e.test/personal.gif)"])
}

@Test func editorPickerResolvesUnavailableSelectionBeforeRenderingEntries() throws {
    let snapshot = try pickerSnapshot()
    for key in ["mine", "site:yct", "gh:o/r/hidden", "deleted-group"] {
        let content = MediaStickerPickerContent(snapshot: snapshot, selectedKey: key)
        #expect(content.selectionKey == "site:xhj")
        #expect(content.entries.map(\.insertion) == [" :xhj004: "])
    }
    // Valid built-in and subscribed selections must not be reset on unrelated emissions.
    #expect(MediaStickerPickerContent(snapshot: snapshot, selectedKey: "site:ac").entries.map(\.insertion) == [" :ac01: "])
    let subscribed = MediaStickerPickerContent(snapshot: snapshot, selectedKey: "gh:o/r/cats")
    #expect(subscribed.selectionKey == "gh:o/r/cats")
    #expect(subscribed.entries.map(\.insertion) == ["![cat](https://e.test/cat.gif)"])

    var changed = try #require(snapshot.object)
    changed["arrangedGroupKeys"] = .array([.string("gh:o/r/cats"), .string("site:ac"), .string("fluent")])
    let replaced = MediaStickerPickerContent(snapshot: .object(changed), selectedKey: "site:xhj")
    #expect(replaced.groups.map(\.id) == ["gh:o/r/cats", "site:ac", "fluent"])
    #expect(replaced.selectionKey == "site:ac")
    #expect(replaced.entries.map(\.insertion) == [" :ac01: "])

    // A removed selection cannot keep the menu bound to an absent tag, including empty loads.
    let empty = MediaStickerPickerContent(snapshot: .null, selectedKey: "site:ac")
    #expect(empty.selectionKey == "")
    #expect(empty.entries.isEmpty)
    changed["groupLayout"] = .object(["hidden": .array([.string("site:ac"), .string("fluent")])])
    let subscriptionOnly = MediaStickerPickerContent(snapshot: .object(changed), selectedKey: "mine")
    #expect(subscriptionOnly.selectionKey == "gh:o/r/cats")
    #expect(subscriptionOnly.entries.map(\.id) == ["https://e.test/cat.gif"])
    changed["arrangedGroupKeys"] = .array([.string("mine")])
    let personalOnly = MediaStickerPickerContent(snapshot: .object(changed), selectedKey: "mine")
    #expect(personalOnly.groups.isEmpty)
    #expect(personalOnly.selectionKey == "")
    #expect(personalOnly.entries.isEmpty)
}

@Test func availablePickerEntriesStillInsertCanonicalShortcodesUnicodeAndSubscriptionMarkdown() throws {
    var snapshot = try #require(pickerSnapshot().object)
    snapshot["groupLayout"] = .object(["hidden": .array([])])
    var interaction = MediaStickerInteraction(mode: .picker)
    for (key, expected) in [
        ("site:ac", " :ac01: "), ("site:yct", " :yct001: "),
        ("site:xhj", " :xhj004: "), ("fluent", "😀"),
        ("gh:o/r/cats", "![cat](https://e.test/cat.gif)")
    ] {
        let content = MediaStickerPickerContent(snapshot: .object(snapshot), selectedKey: key)
        #expect(content.selectionKey == key)
        let entry = try #require(content.entries.first)
        #expect(interaction.activate(entry) == .insert(expected))
    }
    #expect(interaction.selection.isEmpty)
}

private func pickerSnapshot() throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"mine":[{"url":"https://e.test/personal.gif","name":"saved"}],
     "arrangedGroupKeys":["mine","site:xhj","gh:o/r/cats","site:ac","site:yct","gh:o/r/hidden","fluent"],
     "groupLayout":{"hidden":["site:yct"]},
     "subscriptions":[{"slug":"o/r","folders":[
       {"key":"gh:o/r/cats","path":"cats","hidden":false,"entries":[{"url":"https://e.test/cat.gif","name":"cat"}]},
       {"key":"gh:o/r/hidden","path":"hidden","hidden":true,"entries":[{"url":"https://e.test/hidden.gif"}]}]}],
     "siteGroups":[
       {"key":"site:ac","entries":[{"url":"https://e.test/ac.png","shortcode":" :ac01: "}]},
       {"key":"site:yct","entries":[{"url":"https://e.test/yct.gif","shortcode":" :yct001: "}]},
       {"key":"site:xhj","entries":[{"url":"https://e.test/xhj.gif","shortcode":" :xhj004: "}]},
       {"key":"fluent","entries":[{"character":"😀"}]}]}
    """#.utf8))
}
