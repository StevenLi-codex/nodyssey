import SwiftUI
import UIKit

@MainActor final class NaturalParagraphState: ObservableObject {
    @Published var present = true
    @Published var active = true
    let lifetime = NativeRichSelectionLifetime()
    let app = NativeAppModel()
    var images: [String] = []
    var links: [String] = []
    var captured: [String: (String, String?) -> Void] = [:]
    var actions: NativeRichTextActions {
        .init(onImage: { [weak self] url, _ in self?.images.append(url) }, imageTapUsesOwner: true,
              attachmentContent: { [weak self] url, alt, inherited in
                  if let action = inherited.onImage { self?.captured[url] = action }
                  return AnyView(NativeRichImage(url: url, alt: alt, actions: inherited).environmentObject(self!.app))
              }, onLink: { [weak self] in self?.links.append($0) })
    }
}

private struct NaturalParagraphHost: View {
    @ObservedObject var state: NaturalParagraphState
    var body: some View {
        VStack(alignment: .leading) {
            if state.present {
                NativeRichTextView(nodes: [.paragraph([
                    .text("opening before 中文🙂 ", .init()),
                    .sticker(url: "https://example.invalid/sticker.png", alt: "sticker"),
                    .text(" between ", .init()),
                    .image(url: "https://example.invalid/inline.png", alt: "inline"),
                    .text(" after ending", .init()),
                    .link(" link", "https://example.invalid/link", .init())
                ])], actions: state.actions)
                .environment(\.nativeRichSelectionEnabled, true)
                .environment(\.nativeRichSelectionActive, state.active)
                .environment(\.nativeRichSelectionLifetimes, [state.lifetime])
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environmentObject(state.app)
    }
}

@MainActor func behaviorParagraphs(_ root: UIViewController) -> [NativeParagraphController] {
    if let paragraph = root as? NativeParagraphController { return [paragraph] }
    return root.children.flatMap { behaviorParagraphs($0) }
}

@MainActor private func waitForBehavior(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<50 {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }
    return predicate()
}

@MainActor private func attachmentObjects(_ paragraph: NativeParagraphController) -> [NativeInlineTextAttachment] {
    let text = paragraph.textView.attributedText ?? NSAttributedString(string: "")
    var values: [NativeInlineTextAttachment] = []
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { item, _, _ in
        if let attachment = item as? NativeInlineTextAttachment { values.append(attachment) }
    }
    return values
}

@available(iOS 17.0, *)
@MainActor private func replay(_ action: UIAction) {
    let button = UIButton(type: .system)
    button.addAction(action, for: .primaryActionTriggered)
    button.sendActions(for: .primaryActionTriggered)
}

/// Natural SwiftUI ownership. No paragraph frame assignment or manual provider creation/loadView.
/// UIAction is the unchanged shipping return block shared with its delegate in the staged copy.
@MainActor func runNaturalParagraphBehavior(in root: UIHostingController<AnyView>) async -> ([String: Bool], [String: Any]) {
    let keys = ["natural-textkit-provider-mounted", "mixed-copy-spans-attachments",
                "retained-image-rejected-after-revoke", "retained-image-rejected-after-reactivate",
                "retained-primary-uiaction-rejected-after-revoke", "retained-primary-uiaction-rejected-after-reactivate",
                "current-image-and-primary-uiaction-positive", "dismantle-clears-copy-hosts-and-actions"]
    var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, false) })
    var detail: [String: Any] = [:]
    let state = NaturalParagraphState()
    root.rootView = AnyView(NaturalParagraphHost(state: state))
    guard await waitForBehavior({ behaviorParagraphs(root).contains {
        $0.textView.window != nil && $0.textView.text.hasPrefix("opening before 中文🙂 ")
    } }), let paragraph = behaviorParagraphs(root).first(where: {
        $0.textView.text.hasPrefix("opening before 中文🙂 ")
    }) else {
        return (result, ["blocker": "Natural paragraph did not mount"])
    }
    // Let the normal SwiftUI/TextKit display pass install providers, without forcing layout.
    try? await Task.sleep(nanoseconds: 500_000_000)
    let text = paragraph.textView
    let attachments = attachmentObjects(paragraph)
    var providers: [NSTextAttachmentViewProvider] = []
    if let manager = text.textLayoutManager, let content = manager.textContentManager {
        manager.enumerateTextLayoutFragments(from: content.documentRange.location, options: []) { fragment in
            providers.append(contentsOf: fragment.textAttachmentViewProviders)
            return true
        }
    }
    let providerDetails: [[String: Any]] = providers.map { provider in
        let view = provider.view
        return ["provider": String(describing: ObjectIdentifier(provider)),
                "attachmentMatches": attachments.contains { $0 === provider.textAttachment },
                "inWindow": view?.window === text.window && text.window != nil,
                "hasView": view != nil,
                "matchesHostView": attachments.contains { $0.host?.viewIfLoaded === view && view != nil },
                "boundsWidth": view?.bounds.width ?? 0, "boundsHeight": view?.bounds.height ?? 0]
    }
    detail["providers"] = providerDetails
    detail["attachmentCount"] = attachments.count
    detail["paragraphBounds"] = [text.bounds.width, text.bounds.height]
    detail["hostInWindow"] = attachments.map { $0.host?.viewIfLoaded?.window != nil }
    result["natural-textkit-provider-mounted"] = attachments.count == 2 && providers.count == 2 && !text.bounds.isEmpty &&
        providerDetails.allSatisfy { ($0["attachmentMatches"] as? Bool) == true && ($0["inWindow"] as? Bool) == true &&
            ($0["boundsWidth"] as? CGFloat ?? 0) > 0 && ($0["boundsHeight"] as? CGFloat ?? 0) > 0 }
    let selected = "before 中文🙂 \u{fffc} between \u{fffc} after"
    let range = (text.text as NSString).range(of: selected)
    let sentinel = "COPY-SENTINEL-" + UUID().uuidString
    UIPasteboard.general.string = sentinel
    if range.location != NSNotFound {
        text.selectedRange = range
        text.copy(nil)
    }
    detail["selectedRange"] = [range.location, range.length]
    detail["selectedText"] = range.location == NSNotFound ? "MISSING" : (text.text as NSString).substring(with: range)
    detail["pasteboard"] = UIPasteboard.general.string ?? "nil"
    // UIKit plain-text export omits object replacement characters, not adjacent text.
    let expectedCopy = selected.replacingOccurrences(of: "\u{fffc}", with: "")
    detail["expectedPlainTextCopy"] = expectedCopy
    result["mixed-copy-spans-attachments"] = range.location != NSNotFound && range.length < (text.text as NSString).length &&
        UIPasteboard.general.string == expectedCopy && UIPasteboard.general.string != sentinel && text.selectedRange == range &&
        selected.filter { $0 == "\u{fffc}" }.count == 2

    guard #available(iOS 17.0, *), let oldImage = state.captured["https://example.invalid/inline.png"] else {
        detail["blocker"] = "Requires iOS17+ real UIAction and captured shipping fenced image closure"
        return (result, detail)
    }
    let url = URL(string: "nodyssey-inline://item/5")!
    let oldAction = paragraph.behaviorPrimaryActionForLink(url)
    oldImage("https://example.invalid/inline.png", "inline")
    replay(oldAction)
    let initialPositive = state.images == ["https://example.invalid/inline.png"] && state.links == ["https://example.invalid/link"]
    let initialCounts = [state.images.count, state.links.count]
    state.lifetime.revoke()
    state.active = false
    oldImage("https://example.invalid/inline.png", "inline")
    replay(oldAction)
    result["retained-image-rejected-after-revoke"] = initialPositive && state.images.count == initialCounts[0]
    result["retained-primary-uiaction-rejected-after-revoke"] = initialPositive && state.links.count == initialCounts[1]
    UIPasteboard.general.string = sentinel
    text.copy(nil)
    let revokedPasteboard = UIPasteboard.general.string
    let revokedCopySafe = revokedPasteboard == nil || revokedPasteboard == "" || revokedPasteboard == sentinel
    detail["revokedPasteboard"] = revokedPasteboard ?? "nil"
    detail["revokedCopySafe"] = revokedCopySafe
    detail["revokedTextLength"] = text.attributedText.length
    _ = await waitForBehavior({ !paragraph.isActive })
    try? await Task.sleep(nanoseconds: 150_000_000)
    state.active = true
    let reactivated = await waitForBehavior({ paragraph.isActive && paragraph.textView.attributedText.length > 0 })
    oldImage("https://example.invalid/inline.png", "inline")
    replay(oldAction)
    result["retained-image-rejected-after-reactivate"] = reactivated && state.images.count == initialCounts[0]
    result["retained-primary-uiaction-rejected-after-reactivate"] = reactivated && state.links.count == initialCounts[1]
    guard let currentImage = state.captured["https://example.invalid/inline.png"] else { return (result, detail) }
    let currentAction = paragraph.behaviorPrimaryActionForLink(url)
    currentImage("https://example.invalid/inline.png", "inline")
    replay(currentAction)
    result["current-image-and-primary-uiaction-positive"] = initialPositive && reactivated &&
        state.images.count == initialCounts[0] + 1 && state.links.count == initialCounts[1] + 1
    let newAttachments = attachmentObjects(paragraph)
    let newHosts = newAttachments.compactMap(\.host)
    let counts = [state.images.count, state.links.count]
    state.present = false
    let removed = await waitForBehavior({ !paragraph.isActive && paragraph.parent == nil })
    currentImage("https://example.invalid/inline.png", "inline")
    oldImage("https://example.invalid/inline.png", "inline")
    replay(currentAction)
    replay(oldAction)
    UIPasteboard.general.string = sentinel
    text.copy(nil)
    let dismantledPasteboard = UIPasteboard.general.string
    let dismantledCopySafe = dismantledPasteboard == nil || dismantledPasteboard == "" || dismantledPasteboard == sentinel
    detail["dismantledPasteboard"] = dismantledPasteboard ?? "nil"
    result["dismantle-clears-copy-hosts-and-actions"] = removed && text.attributedText.length == 0 &&
        text.selectedRange.length == 0 && !text.isSelectable && revokedCopySafe && dismantledCopySafe &&
        state.images.count == counts[0] && state.links.count == counts[1] &&
        newAttachments.count == 2 && newAttachments.allSatisfy { $0.host == nil } &&
        newHosts.allSatisfy { $0.parent == nil && $0.viewIfLoaded?.window == nil }
    detail["initialPositive"] = initialPositive
    detail["reactivated"] = reactivated
    detail["dismantled"] = removed
    detail["finalImageCount"] = state.images.count
    detail["finalLinkCount"] = state.links.count
    return (result, detail)
}
