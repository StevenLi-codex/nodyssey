import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeMedia

@Test func browsingDoesNotSelectAndSelectionDoesNotInsert() throws {
    let sticker = try #require(MediaSticker(.object(["url": .string("https://e.test/a.gif"), "name": .string("A") ])))
    var interaction = MediaStickerInteraction(mode: .browser)
    #expect(interaction.activate(sticker) == .preview(sticker))
    #expect(interaction.selection.isEmpty)
    interaction.beginSelection()
    #expect(interaction.activate(sticker) == .none)
    #expect(interaction.selection == [sticker.id])
    interaction.endSelection()
    #expect(interaction.selection.isEmpty)
    #expect(interaction.activate(sticker) == .preview(sticker))
}

@Test func pickerKeepsShortcodeAndUnicodeAndCannotEnterSelection() throws {
    let shortcode = try #require(MediaSticker(.object(["url": .string("https://e.test/site.png"), "name": .string("smile"), "shortcode": .string(":ac1:")])))
    let unicode = try #require(MediaSticker(.object(["character": .string("😀")])))
    var interaction = MediaStickerInteraction(mode: .picker)
    interaction.beginSelection()
    #expect(!interaction.selecting)
    #expect(interaction.activate(shortcode) == .insert(":ac1:"))
    #expect(interaction.activate(unicode) == .insert("😀"))
    #expect(interaction.selection.isEmpty)
}

@Test func selectionReconcilesRemovedEntriesAndRejectsUnicode() throws {
    let sticker = try #require(MediaSticker(.object(["url": .string("https://e.test/a.gif") ])))
    let unicode = try #require(MediaSticker(.object(["character": .string("😀")])))
    var interaction = MediaStickerInteraction(mode: .browser)
    interaction.selectAll([sticker, unicode])
    #expect(interaction.selection == [sticker.id])
    #expect(interaction.activate(unicode) == .none)
    interaction.reconcile([unicode])
    #expect(interaction.selection.isEmpty)
    #expect(interaction.selecting)
}
