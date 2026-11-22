import SwiftUI

private struct NativeRichSelectionEnabledKey: EnvironmentKey { static let defaultValue = false }
private struct NativeRichSelectionActiveKey: EnvironmentKey { static let defaultValue = true }
private struct NativeRichSelectionLifetimesKey: EnvironmentKey { static let defaultValue: [NativeRichSelectionLifetime] = [] }

/// A container can synchronously revoke UIKit selection before its SwiftUI branch changes.
@MainActor final class NativeRichSelectionLifetime: ObservableObject {
    private var owners: [UUID: () -> Void] = [:]
    func register(_ id: UUID, revoke: @escaping () -> Void) { owners[id] = revoke }
    func remove(_ id: UUID) { owners[id] = nil }
    func revoke() { for callback in Array(owners.values) { callback() } }
}

extension EnvironmentValues {
    var nativeRichSelectionEnabled: Bool {
        get { self[NativeRichSelectionEnabledKey.self] }
        set { self[NativeRichSelectionEnabledKey.self] = newValue }
    }
    var nativeRichSelectionActive: Bool {
        get { self[NativeRichSelectionActiveKey.self] }
        set { self[NativeRichSelectionActiveKey.self] = newValue }
    }
    var nativeRichSelectionLifetimes: [NativeRichSelectionLifetime] {
        get { self[NativeRichSelectionLifetimesKey.self] }
        set { self[NativeRichSelectionLifetimesKey.self] = newValue }
    }
}

#if os(iOS) && canImport(UIKit)
import UIKit

/// Public-view contract for the navigation owner. Queries are bounded to its route root.
/// Never identify SwiftUI/UIKit private classes or replace system selection recognizers.
@MainActor enum NativeRichInteractionBoundary {
    enum Role { case imageActivation, imageRetryConsent, imageZoom }

    static func hasActiveTextSelection(in root: UIView) -> Bool {
        descendants(root).contains { view in
            guard let text = view as? NativeSelectableTextView else { return false }
            return text.selectionActive && text.selectedRange.length > 0 && visible(text, in: root)
        }
    }

    static func containsInteraction(at point: CGPoint, in root: UIView, includePlainText: Bool = true) -> Bool {
        descendants(root).contains { view in
            let local = view.convert(point, from: root)
            guard visible(view, in: root), view.bounds.contains(local) else { return false }
            if let text = view as? NativeSelectableTextView, text.selectionActive {
                if !includePlainText && !text.hasInlineAction(at: local) { return false }
            } else if !(view is NativeRichInteractionMarkerView) { return false }
            var ancestor = view.superview
            while let parent = ancestor {
                if parent.clipsToBounds && !parent.bounds.contains(parent.convert(point, from: root)) { return false }
                if parent === root { break }
                ancestor = parent.superview
            }
            return true
        }
    }

    private static func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { descendants($0) } }
    private static func visible(_ view: UIView, in root: UIView) -> Bool {
        guard let window = root.window, view.window === window, !view.bounds.isEmpty else { return false }
        var current: UIView? = view
        while let item = current {
            guard !item.isHidden, item.alpha > 0.01 else { return false }
            if item.clipsToBounds && !item.bounds.intersects(item.convert(view.bounds, from: view)) { return false }
            if item === root { return true }
            current = item.superview
        }
        return false
    }
}

final class NativeRichInteractionMarkerView: UIView {
    var role: NativeRichInteractionBoundary.Role = .imageActivation
}

private struct NativeRichInteractionMarker: UIViewRepresentable {
    let role: NativeRichInteractionBoundary.Role
    func makeUIView(context: Context) -> NativeRichInteractionMarkerView {
        let view = NativeRichInteractionMarkerView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.role = role
        return view
    }
    func updateUIView(_ view: NativeRichInteractionMarkerView, context: Context) { view.role = role }
}

extension View {
    func nativeRichInteractionBoundary(_ role: NativeRichInteractionBoundary.Role) -> some View {
        background(NativeRichInteractionMarker(role: role).allowsHitTesting(false))
    }
}

/// Exactly one read-only TextKit owner per canonical paragraph/heading/table cell.
/// Existing rich blocks, disclosure, tables, code and poll ownership are not replaced.
struct NativeSelectableParagraph: UIViewControllerRepresentable {
    let inlines: [NativeInlineNode]
    let actions: NativeRichTextActions
    let role: NativeRichTextRole
    let headingLevel: Int?
    let inTable: Bool
    let stickerSize: Double
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> NativeParagraphController { NativeParagraphController() }
    func updateUIViewController(_ controller: NativeParagraphController, context: Context) {
        controller.update(inlines: inlines, actions: actions, role: role, headingLevel: headingLevel,
            inTable: inTable, stickerSize: stickerSize, environment: environment)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: NativeParagraphController, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return uiViewController.textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    static func dismantleUIViewController(_ controller: NativeParagraphController, coordinator: ()) { controller.dispose() }
}

final class NativeSelectableTextView: UITextView {
    var selectionActive = true

    // Read-only text keeps its system tap and long-press recognizers. Only
    // inline actions, not the paragraph's entire rectangle, own a drag start.
    func hasInlineAction(at point: CGPoint) -> Bool {
        guard let character = characterRange(at: point), let attributedText else { return false }
        let offset = offset(from: beginningOfDocument, to: character.start)
        guard offset >= 0, offset < attributedText.length else { return false }
        return attributedText.attribute(.link, at: offset, effectiveRange: nil) != nil ||
            attributedText.attribute(.attachment, at: offset, effectiveRange: nil) != nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { selectedRange = NSRange(location: 0, length: 0); resignFirstResponder() }
    }
}

@MainActor final class NativeParagraphController: UIViewController, UITextViewDelegate {
    let textView = NativeSelectableTextView(usingTextLayoutManager: true)
    private(set) var isActive = false
    private var inlines: [NativeInlineNode] = []
    private var actions = NativeRichTextActions()
    private var attachments: [Int: NativeInlineTextAttachment] = [:]
    private var lifetimes: [NativeRichSelectionLifetime] = []
    private let registration = UUID()
    private var revision = UUID()

    override func loadView() {
        textView.isEditable = false
        textView.isSelectable = false
        textView.selectionActive = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = self
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view = textView
    }

    func update(inlines nodes: [NativeInlineNode], actions: NativeRichTextActions, role: NativeRichTextRole,
                headingLevel: Int?, inTable: Bool, stickerSize: Double, environment: EnvironmentValues) {
        loadViewIfNeeded()
        for owner in lifetimes { owner.remove(registration) }
        lifetimes = environment.nativeRichSelectionLifetimes
        for owner in lifetimes { owner.register(registration) { [weak self] in self?.revoke() } }
        guard environment.nativeRichSelectionActive else { revoke(); return }
        let contentChanged = inlines != nodes
        if contentChanged { revoke() }
        if !isActive {
            isActive = true
            textView.selectionActive = true
            textView.isSelectable = true
        }
        inlines = nodes
        self.actions = actions
        let category = environment.dynamicTypeSize.nativeContentSizeCategory
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        let textStyle: UIFont.TextStyle = role == .signature ? .footnote : headingLevel.map {
            switch $0 { case 1: .largeTitle; case 2: .title1; case 3: .title2; case 4: .title3; default: .headline }
        } ?? .body
        let base = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: traits)
        let color: UIColor = role == .signature ? .secondaryLabel : .label
        let output = NSMutableAttributedString(string: "")
        var attachmentGeometryChanged = false
        for (index, node) in nodes.enumerated() {
            var style = NativeInlineStyle()
            let string: String
            var link: URL?
            switch node {
            case let .text(text, value): string = text; style = value
            case let .link(text, url, value):
                string = text; style = value
                if NativeRichLinkPolicy.isAllowed(url), actions.onLink != nil { link = URL(string: "nodyssey-inline://item/\(index)") }
            case let .quoteRef(name, floor, url):
                string = "@\(name) \(floor)"; style.bold = true
                if NativeRichLinkPolicy.isAllowed(url), actions.onQuoteReference != nil { link = URL(string: "nodyssey-inline://item/\(index)") }
            case .lineBreak: string = "\n"
            case let .image(url, alt), let .sticker(url, alt):
                let attachment = attachments[index] ?? NativeInlineTextAttachment(owner: self)
                attachments[index] = attachment
                let size: CGSize
                if case .sticker = node { size = CGSize(width: stickerSize, height: stickerSize) }
                else { size = CGSize(width: inTable ? 120 : 96, height: inTable ? 90 : 72) }
                let bounds = CGRect(origin: CGPoint(x: 0, y: base.descender), size: size)
                if attachment.renderingBounds != bounds {
                    attachment.renderingBounds = bounds
                    attachmentGeometryChanged = true
                }
                var fenced = actions
                let token = revision
                fenced.onImage = actions.onImage.map { action in { [weak self] url, alt in
                    guard let self, self.isActive, self.revision == token else { return }
                    action(url, alt)
                } }
                let content = actions.attachmentContent?(url, alt, fenced) ?? AnyView(NativeRichImage(url: url, alt: alt, actions: fenced))
                // A new hosting root does not inherit SwiftUI environment or environmentObject.
                // The content owner injects its app explicitly; copy the presentation values too.
                attachment.update(root: AnyView(content.environment(\.self, environment)), owner: self)
                output.append(NSAttributedString(attachment: attachment))
                continue
            }
            var font = style.code ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
            var flags = font.fontDescriptor.symbolicTraits
            if style.bold || headingLevel != nil { flags.insert(.traitBold) }
            if style.italic { flags.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(flags) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if style.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if style.code { attributes[.backgroundColor] = UIColor.secondaryLabel.withAlphaComponent(0.12) }
            if let link { attributes[.link] = link }
            output.append(NSAttributedString(string: string, attributes: attributes))
        }
        let selection = textView.selectedRange
        if !textView.attributedText.isEqual(to: output) {
            let sameString = textView.attributedText.string == output.string
            textView.attributedText = output
            if sameString && NSMaxRange(selection) <= output.length { textView.selectedRange = selection }
        } else if attachmentGeometryChanged {
            textView.invalidateIntrinsicContentSize()
        }
        // Assigning attributedText already invalidates UIKit layout. Repeated
        // SwiftUI updates with the same paragraph must not request another pass.
    }

    func dispose() {
        revoke()
        for lifetime in lifetimes { lifetime.remove(registration) }
        lifetimes.removeAll()
    }

    /// Discard hidden copy data and hosted image actions before fold/tab/identity transitions.
    func revoke() {
        guard isActive else { return }
        isActive = false
        inlines = []
        actions = NativeRichTextActions()
        revision = UUID()
        textView.selectionActive = false
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.resignFirstResponder()
        textView.isSelectable = false
        textView.attributedText = NSAttributedString(string: "")
        for attachment in attachments.values { attachment.removeHost() }
        attachments.removeAll()
    }

    func activate(_ url: URL) {
        guard isActive, url.scheme == "nodyssey-inline", url.host == "item",
              let index = Int(url.lastPathComponent), inlines.indices.contains(index) else { return }
        switch inlines[index] {
        case let .link(_, raw, _) where NativeRichLinkPolicy.isAllowed(raw): actions.onLink?(raw)
        case let .quoteRef(name, floor, raw) where NativeRichLinkPolicy.isAllowed(raw): actions.onQuoteReference?(name, floor, raw)
        default: break
        }
    }
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if interaction == .invokeDefaultAction { activate(URL) }
        return false
    }
    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard isActive, case let .link(url) = textItem.content else { return nil }
        let token = revision
        return UIAction { [weak self] _ in
            guard let self, self.revision == token else { return }
            self.activate(url)
        }
    }
}

/// The paragraph owns attachment/hosting identities; transient TextKit providers borrow them.
@MainActor final class NativeInlineTextAttachment: NSTextAttachment {
    weak var owner: NativeParagraphController?
    private(set) var host: UIHostingController<AnyView>?
    // Nonzero NSTextAttachment.bounds prevents natural view mounting on iOS 26.5.
    // Keep that property zero and report the unchanged geometry through the provider.
    fileprivate var renderingBounds = CGRect.zero
    init(owner: NativeParagraphController) {
        self.owner = owner
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var usesTextAttachmentView: Bool { true }
    func update(root: AnyView, owner: NativeParagraphController) {
        if let host { host.rootView = root; return }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        owner.addChild(host)
        self.host = host
        host.didMove(toParent: owner)
    }
    func removeHost() {
        guard let host else { return }
        host.willMove(toParent: nil)
        host.rootView = AnyView(EmptyView())
        host.view.removeFromSuperview()
        host.removeFromParent()
        self.host = nil
    }
    override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = NativeInlineAttachmentProvider(textAttachment: self, parentView: parentView, textLayoutManager: textContainer?.textLayoutManager, location: location)
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

private final class NativeInlineAttachmentProvider: NSTextAttachmentViewProvider {
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        MainActor.assumeIsolated {
            (textAttachment as? NativeInlineTextAttachment)?.renderingBounds ?? .zero
        }
    }
    override func loadView() {
        // UIKit requests attachment views on its UI thread; TextKit's ObjC override is nonisolated.
        MainActor.assumeIsolated {
            guard let attachment = textAttachment as? NativeInlineTextAttachment, let host = attachment.host else { return }
            view = host.view
        }
    }
}

private extension DynamicTypeSize {
    var nativeContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall; case .small: .small; case .medium: .medium; case .large: .large
        case .xLarge: .extraLarge; case .xxLarge: .extraExtraLarge; case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium; case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge; case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        default: .large
        }
    }
}
#endif
