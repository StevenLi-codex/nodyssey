import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeMedia

@Test func groupProjectionHonorsFolderHiddenAndUsesShortcodes() throws {
    let snapshot = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
    {"mine":[{"url":"https://e.test/a.gif","name":"a"}],
     "arrangedGroupKeys":["gh:o/r/f","site:ac","mine"],
     "groupLayout":{"hidden":["mine"]},
     "siteGroups":[{"key":"site:ac","entries":[
       {"type":"Sticker","shortcode":":ac1:","name":"smile","url":"https://e.test/site.png"},
       {"type":"Unicode","character":"😀"}]}],
     "subscriptions":[{"slug":"o/r","folders":[{"key":"gh:o/r/f","path":"f","hidden":true,"name":"Folder","entries":[]}]}]}
    """#.utf8))
    let groups = MediaStickerGroup.groups(snapshot)
    #expect(groups.map(\.id) == ["gh:o/r/f", "site:ac", "mine"])
    #expect(groups.filter { !$0.hidden }.map(\.id) == ["site:ac"])
    #expect(groups[1].entries.map(\.insertion) == [":ac1:", "😀"])
    #expect(groups[2].entries[0].insertion == "![a](https://e.test/a.gif)")
    #expect(MediaStickerGroup.groups(.null).isEmpty)
}

@Test func subscriptionSelectionPinsInspectedURLAndSHA() throws {
    var draft = MediaSubscriptionDraft()
    let listing: JSONValue = .object(["sha": .string("pinned-sha"), "folders": .array([
        .object(["path": .string("cats"), "files": .array([.string("cats/a.gif")])]),
        .object(["path": .string("dogs"), "files": .array([])])])])
    try draft.accept(listing, url: "https://github.com/o/r/tree/main")
    draft.selected = ["cats"]
    let args = try draft.arguments(currentURL: "https://github.com/o/r/tree/main")
    #expect(args["expectedSha"] == .string("pinned-sha"))
    #expect(args["paths"] == .array([.string("cats")]))
    #expect(throws: NativeFailure.self) { try draft.arguments(currentURL: "https://github.com/o/other") }
    draft.selected = ["not-in-listing"]
    #expect(throws: NativeFailure.self) { try draft.arguments(currentURL: "https://github.com/o/r/tree/main") }
    draft.invalidate()
    #expect(draft.selected.isEmpty)
    #expect(throws: NativeFailure.self) { try draft.arguments(currentURL: "https://github.com/o/r/tree/main") }
}

@Test func pickerEscapesUserNamesWithoutChangingURLIdentity() throws {
    let sticker = try #require(MediaSticker(.object(["url": .string("https://e.test/a(b).gif"), "name": .string("x] [unsafe") ])))
    #expect(sticker.id == "https://e.test/a(b).gif")
    #expect(sticker.insertion == #"![x\] \[unsafe](https://e.test/a%28b%29.gif)"#)
}

@Test func pastedLinksDeduplicateAndNeverAdmitHTTP() throws {
    let links = MediaLinkPreview.parse("![A](https://e.test/a.gif) http://e.test/b.png https://e.test/a.gif https://e.test/猫.png, ")
    #expect(links.map(\.url) == ["https://e.test/a.gif", "https://e.test/猫.png"])
    #expect(links.map(\.name) == ["a", "猫"])
}

@Test func editingPublicHostFieldsNeverReplacesMaskedCredentials() throws {
    var draft = MediaHostDraft(provider: "CUSTOM", snapshot: .object([
        "siteUrl": .string("https://upload.example.test"), "hasToken": .bool(true),
        "custom": .object(["fileField": .string("image"), "hasHeaderValue": .bool(true), "hasFormFields": .bool(true)])
    ]))
    draft.siteURL = "https://other.example.test"
    let patch = try draft.arguments()
    #expect(patch["token"] == nil)
    #expect(patch["custom"]?["headerValue"] == nil)
    #expect(patch["custom"]?["formFields"] == nil)
    draft.token = .clear
    draft.headerValue = .replace("new-secret")
    draft.formFields = .clear
    let replacement = try draft.arguments()
    #expect(replacement["token"] == .string(""))
    #expect(replacement["custom"]?["headerValue"] == .string("new-secret"))
    #expect(replacement["custom"]?["formFields"] == .string(""))
}
