import SwiftUI
import UIKit

/// Executes shipping UITextView/TextKit code, not a reimplementation. No genuine-touch claim.
@MainActor func runNativeRichSelectionBehavior(in root: UIViewController) -> [String: Bool] {
    var results: [String: Bool] = [:]
    let paragraph = NativeParagraphController()
    root.addChild(paragraph)
    root.view.addSubview(paragraph.view)
    paragraph.view.frame = CGRect(x: 10, y: 80, width: 320, height: 180)
    paragraph.didMove(toParent: root)
    var links: [String] = []
    var quotes: [String] = []
    var images: [String] = []
    let app = NativeAppModel() // Explicit transport/environment boundary, supplied by this runner.
    let actions = NativeRichTextActions(onImage: { url, _ in images.append(url) }, imageTapUsesOwner: true,
        attachmentContent: { url, alt, inherited in
            AnyView(NativeRichImage(url: url, alt: alt, actions: inherited).environmentObject(app))
        }, onLink: { links.append($0) }, onQuoteReference: { _, floor, _ in quotes.append(floor) })
    let lifetime = NativeRichSelectionLifetime()
    var environment = EnvironmentValues()
    environment.nativeRichSelectionEnabled = true
    environment.nativeRichSelectionLifetimes = [lifetime]
    let nodes: [NativeInlineNode] = [
        .text("prefix 中文🙂 ", .init()), .text("bold", .init(bold: true, italic: true, strikethrough: true)),
        .link("link", "https://example.invalid/post", .init(code: true)),
        .quoteRef(name: "reader", floor: "#12", url: "#12"),
        .sticker(url: "https://example.invalid/a.png", alt: "sticker"),
        .text(" suffix", .init()), .image(url: "https://example.invalid/a.png", alt: "inline"), .lineBreak,
        .link("unsafe", "javascript:alert(1)", .init()), .text("tail", .init())
    ]
    func update(_ value: [NativeInlineNode] = nodes, role: NativeRichTextRole = .body) {
        paragraph.update(inlines: value, actions: actions, role: role, headingLevel: nil,
            inTable: false, stickerSize: 24, environment: environment)
    }
    update()
    let text = paragraph.textView
    let original = text.attributedText!
    let expected = "prefix 中文🙂 boldlink@reader #12\u{fffc} suffix\u{fffc}\nunsafetail"
    results["canonical-mixed-no-token-fragmentation"] = text.text == expected && text.textLayoutManager != nil
    let range = (text.text as NSString).range(of: "中文🙂 boldlink@reader #12")
    text.selectedRange = range
    text.copy(nil)
    results["mixed-native-partial-copy"] = UIPasteboard.general.string == "中文🙂 boldlink@reader #12" && range.length < (text.text as NSString).length
    var attachments: [NativeInlineTextAttachment] = []
    original.enumerateAttribute(.attachment, in: NSRange(location: 0, length: original.length)) { value, _, _ in
        if let item = value as? NativeInlineTextAttachment { attachments.append(item) }
    }
    let identities = attachments.compactMap { $0.host.map(ObjectIdentifier.init) }
    results["attachments-use-contained-shipping-image-hosts"] = attachments.count == 2 && identities.count == 2 && attachments.allSatisfy { $0.host?.parent === paragraph }
    update()
    var current: [ObjectIdentifier] = []
    text.attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.attributedText.length)) { value, _, _ in
        if let host = (value as? NativeInlineTextAttachment)?.host { current.append(ObjectIdentifier(host)) }
    }
    results["same-render-preserves-selection-and-hosts"] = text.selectedRange == range && current == identities
    let oldDelegate = text.delegate!
    _ = oldDelegate.textView?(text, shouldInteractWith: URL(string: "nodyssey-inline://item/2")!, in: .init(location: 0, length: 0), interaction: .invokeDefaultAction)
    _ = oldDelegate.textView?(text, shouldInteractWith: URL(string: "nodyssey-inline://item/3")!, in: .init(location: 0, length: 0), interaction: .invokeDefaultAction)
    _ = oldDelegate.textView?(text, shouldInteractWith: URL(string: "nodyssey-inline://item/8")!, in: .init(location: 0, length: 0), interaction: .invokeDefaultAction)
    results["links-quotes-use-owner-unsafe-rejected"] = links == ["https://example.invalid/post"] && quotes == ["#12"]
    let bold = original.attribute(.font, at: (expected as NSString).range(of: "bold").location, effectiveRange: nil) as? UIFont
    results["canonical-rich-traits-retained"] = bold?.fontDescriptor.symbolicTraits.contains([.traitBold, .traitItalic]) == true
    results["selection-blocks-custom-back"] = NativeRichInteractionBoundary.hasActiveTextSelection(in: paragraph.view)
    let point = text.convert(CGPoint(x: 2, y: 2), to: root.view)
    results["paragraph-hit-boundary"] = NativeRichInteractionBoundary.containsInteraction(at: point, in: root.view)
    environment.dynamicTypeSize = .accessibility3
    update(role: .signature)
    let font = text.attributedText.attribute(.font, at: 0, effectiveRange: nil) as! UIFont
    let expectedFont = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge))
    results["signature-dynamic-type-semantic-font"] = abs(font.pointSize - expectedFont.pointSize) < 0.01 && text.selectedRange == range
    lifetime.revoke()
    paragraph.activate(URL(string: "nodyssey-inline://item/2")!)
    results["container-revoke-clears-hidden-copy-and-actions"] = text.attributedText.length == 0 && text.selectedRange.length == 0 && !text.isSelectable && links.count == 1 && !NativeRichInteractionBoundary.hasActiveTextSelection(in: paragraph.view) && attachments.allSatisfy { $0.host == nil }
    environment.nativeRichSelectionActive = false
    update()
    results["inactive-tab-never-projects-canonical-data"] = text.attributedText.length == 0 && paragraph.children.isEmpty
    environment.nativeRichSelectionActive = true
    update([.text("replacement alpha beta", .init())])
    text.selectedRange = (text.text as NSString).range(of: "alpha")
    text.copy(nil)
    results["reveal-restores-new-range-owner"] = UIPasteboard.general.string == "alpha" && text.isSelectable
    // A retained action from the old attachment must not navigate after a revoke/reveal.
    results["revoked-image-hosts-not-reparented"] = attachments.allSatisfy { $0.host == nil }
    paragraph.willMove(toParent: nil)
    paragraph.view.removeFromSuperview()
    paragraph.removeFromParent()
    paragraph.revoke()
    return results
}
