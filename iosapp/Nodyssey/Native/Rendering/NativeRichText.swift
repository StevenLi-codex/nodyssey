import SwiftUI

/// Inherited through recursive blocks and owner-rendered code slots. Semantic fonts
/// preserve Dynamic Type (including the app's font-scale environment), unlike scaling a view.
enum NativeRichTextRole {
    case body, signature

    var textFont: Font { self == .signature ? .footnote : .body }
    var codeFont: Font { .system(self == .signature ? .footnote : .body, design: .monospaced) }
    func headingFont(_ level: Int) -> Font {
        if self == .signature { return .footnote.bold() }
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case 4: return .title3.bold()
        default: return .headline
        }
    }
}

private struct NativeRichTextRoleKey: EnvironmentKey {
    static let defaultValue = NativeRichTextRole.body
}

struct NativeRichTextPresentation: ViewModifier {
    let role: NativeRichTextRole
    @ViewBuilder func body(content: Content) -> some View {
        if role == .signature { content.font(.footnote).foregroundStyle(.secondary) }
        else { content }
    }
}

extension EnvironmentValues {
    var nativeRichTextRole: NativeRichTextRole {
        get { self[NativeRichTextRoleKey.self] }
        set { self[NativeRichTextRoleKey.self] = newValue }
    }
}

/// UI-only callbacks. Owners perform navigation, fetch live poll state, and confirm payments.
/// A nil callback disables its action; the renderer never fabricates a successful mutation.
struct NativeRichTextActions {
    var onImage: ((String, String?) -> Void)?
    var imageTapUsesOwner: Bool
    /// Explicit image environment injection at the content owner; no second image pipeline.
    var attachmentContent: ((String, String?, NativeRichTextActions) -> AnyView)?
    var onVote: ((Int64) -> Void)?
    var onStardust: ((NativeStardustReceive) -> Void)?
    var onLink: ((String) -> Void)?
    var onQuoteReference: ((_ name: String, _ floor: String, _ url: String) -> Void)?
    var onCode: ((NativeCode, NativeCodeAction) -> Void)?
    /// Optional owner-rendered code/report slot, inherited by every recursive container.
    /// The owner retains parsing, settings and per-report override policy. Nil preserves source.
    var codeContent: ((NativeCode, NativeRichTextActions) -> AnyView)?

    init(
        onImage: ((String, String?) -> Void)? = nil,
        imageTapUsesOwner: Bool = false,
        attachmentContent: ((String, String?, NativeRichTextActions) -> AnyView)? = nil,
        onVote: ((Int64) -> Void)? = nil,
        onStardust: ((NativeStardustReceive) -> Void)? = nil,
        onLink: ((String) -> Void)? = nil,
        onQuoteReference: ((_ name: String, _ floor: String, _ url: String) -> Void)? = nil,
        onCode: ((NativeCode, NativeCodeAction) -> Void)? = nil,
        codeContent: ((NativeCode, NativeRichTextActions) -> AnyView)? = nil
    ) {
        self.onImage = onImage
        self.imageTapUsesOwner = imageTapUsesOwner
        self.attachmentContent = attachmentContent
        self.onVote = onVote
        self.onStardust = onStardust
        self.onLink = onLink
        self.onQuoteReference = onQuoteReference
        self.onCode = onCode
        self.codeContent = codeContent
    }
}

enum NativeCodeAction { case adaptedReport, source, compare }

/// Native content for posts, replies, signatures, Readmes, messages, and previews.
/// Decode [NativeRichNode] directly using JSONDecoder; no HTML/JavaScript is involved.
struct NativeRichTextView: View {
    @Environment(\.nativeRichTextRole) private var role
    let nodes: [NativeRichNode]
    var actions: NativeRichTextActions
    /// Conversation bubbles hug a short message instead of taking the column;
    /// posts, previews and Readmes keep the full width they were designed for.
    var expandsWidth = true

    init(nodes: [NativeRichNode], actions: NativeRichTextActions = .init(), expandsWidth: Bool = true) {
        self.nodes = nodes
        self.actions = actions
        self.expandsWidth = expandsWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(nodes.indices, id: \.self) { index in
                NativeRichBlock(node: nodes[index], actions: actions)
            }
        }
        .frame(maxWidth: expandsWidth ? .infinity : nil, alignment: .leading)
        .modifier(NativeRichTextPresentation(role: role))
    }
}

private struct NativeRichBlock: View {
    @Environment(\.nativeRichTextRole) private var role
    let node: NativeRichNode
    let actions: NativeRichTextActions

    @ViewBuilder var body: some View {
        switch node {
        case .paragraph(let inlines):
            NativeInlineContent(inlines: inlines, actions: actions)
        case let .heading(level, inlines):
            NativeInlineContent(inlines: inlines, actions: actions, font: role.headingFont(level), headingLevel: level)
                .accessibilityAddTraits(.isHeader)
        case let .image(url, alt):
            NativeRichImage(url: url, alt: alt, actions: actions)
                .frame(maxWidth: .infinity)
        case .vote(let voteId):
            VStack(alignment: .leading, spacing: 6) {
                Label("Poll", systemImage: "chart.bar.xaxis")
                Text("#\(String(voteId))").font(.caption).foregroundStyle(.secondary)
                Button("View poll") { actions.onVote?(voteId) }
                    .disabled(actions.onVote == nil)
            }
            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case .stardust(let receive):
            VStack(alignment: .leading, spacing: 6) {
                Label("Stardust request", systemImage: "sparkles")
                Text("\(receive.amount) Stardust").font(role == .signature ? .footnote.bold() : .headline)
                if !receive.description.isEmpty { Text(receive.description).textSelection(.enabled) }
                Text("Member #\(String(receive.memberId)) · Reference #\(String(receive.refId))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if receive.onetime { Text("One payment per account").font(.caption) }
                Button("Review payment") { actions.onStardust?(receive) }
                    .disabled(actions.onStardust == nil)
            }
            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case .code(let code):
            if let codeContent = actions.codeContent {
                codeContent(code, actions)
            } else {
                NativeCodeBlock(code: code, actions: actions)
            }
        case .quote(let children):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                AnyView(NativeRichTextView(nodes: children, actions: actions))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .tabs(let tabs):
            NativeRichTabs(tabs: tabs, actions: actions)
        case let .fold(title, children, open):
            NativeRichFold(title: title, children: children, initiallyOpen: open, actions: actions)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•").foregroundStyle(.secondary)
                        AnyView(NativeRichTextView(nodes: items[index], actions: actions))
                    }
                }
            }
        case .table(let cells):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(cells.indices, id: \.self) { row in
                        GridRow {
                            ForEach(cells[row].indices, id: \.self) { column in
                                NativeInlineContent(inlines: cells[row][column], actions: actions, inTable: true)
                                    .frame(minWidth: 100, maxWidth: 280, alignment: .leading)
                                    .padding(10)
                                    .background(row == 0 ? Color.secondary.opacity(0.12) : Color.clear)
                                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
        case .divider: Divider()
        }
    }
}

private struct NativeRichFold: View {
    @Environment(\.nativeRichSelectionActive) private var parentActive
    @Environment(\.nativeRichSelectionLifetimes) private var parentLifetimes
    @StateObject private var selection = NativeRichSelectionLifetime()
    let title: String
    let children: [NativeRichNode]
    let actions: NativeRichTextActions
    @State private var expanded: Bool

    init(title: String, children: [NativeRichNode], initiallyOpen: Bool, actions: NativeRichTextActions) {
        self.title = title
        self.children = children
        self.actions = actions
        _expanded = State(initialValue: initiallyOpen)
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { value in
            if !value { selection.revoke() }
            expanded = value
        })) {
            AnyView(NativeRichTextView(nodes: children, actions: actions))
                .environment(\.nativeRichSelectionActive, parentActive && expanded)
                .environment(\.nativeRichSelectionLifetimes, parentLifetimes + [selection])
                .padding(.top, 8)
        } label: {
            if title.isEmpty { Text("Details") } else { Text(title) }
        }
    }
}

private struct NativeRichTabs: View {
    @Environment(\.nativeRichSelectionActive) private var parentActive
    @Environment(\.nativeRichSelectionLifetimes) private var parentLifetimes
    @StateObject private var selection = NativeRichSelectionLifetime()
    let tabs: [NativeRichTab]
    let actions: NativeRichTextActions
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button {
                            guard selected != index else { return }
                            selection.revoke()
                            selected = index
                        } label: {
                            Text(tabs[index].title)
                                .fontWeight(selected == index ? .semibold : .regular)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(selected == index ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == index ? [.isSelected] : [])
                    }
                }
            }
            // Keep each tab subtree mounted so independent nested folds retain their state.
            ZStack(alignment: .topLeading) {
                ForEach(tabs.indices, id: \.self) { index in
                    AnyView(NativeRichTextView(nodes: tabs[index].children, actions: actions))
                        .environment(\.nativeRichSelectionActive, parentActive && selected == index)
                        .environment(\.nativeRichSelectionLifetimes, parentLifetimes + [selection])
                        .frame(height: selected == index ? nil : 0, alignment: .top)
                        .clipped()
                        .opacity(selected == index ? 1 : 0)
                        .allowsHitTesting(selected == index)
                        .accessibilityHidden(selected != index)
                }
            }
        }
        .onChange(of: tabs.count) { count in
            if selected >= count { selection.revoke(); selected = 0 }
        }
    }
}

struct NativeRichImage: View {
    let url: String
    let alt: String?
    let actions: NativeRichTextActions

    @ViewBuilder var body: some View {
        if NativeRichLinkPolicy.isAllowed(url) {
            // Only the loaded remote leaf is a gallery Button; retry/consent keep their owner.
            NativeRemoteImage(url: url, aspectFit: true, onOpen: actions.imageTapUsesOwner ? actions.onImage.map { open in
                { open(url, alt) }
            } : nil)
                .accessibilityLabel(alt.flatMap { $0.isEmpty ? nil : $0 } ?? "Image")
                .contextMenu {
                    if let onImage = actions.onImage {
                        Button("Open in gallery") { onImage(url, alt) }
                    }
                }
        } else {
            Label(alt ?? "Image unavailable", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
        }
    }
}

private struct NativeInlineContent: View {
    @Environment(\.nativeRichTextRole) private var role
    @Environment(\.dynamicTypeSize) private var dynamicType
    let inlines: [NativeInlineNode]
    let actions: NativeRichTextActions
    var font: Font? = nil
    var inTable = false
    var headingLevel: Int? = nil
    @Environment(\.nativeRichSelectionEnabled) private var nativeSelection
    @ScaledMetric(relativeTo: .body) private var stickerSize = 24.0
    @StateObject private var flowProjection = NativeRenderingMemo<[NativeInlineNode], [NativeInlineNode]>()

    private var hasMedia: Bool {
        inlines.contains { node in
            switch node { case .image, .sticker: true; default: false }
        }
    }

    var body: some View {
        Group {
            #if os(iOS) && canImport(UIKit)
            if nativeSelection {
                NativeSelectableParagraph(inlines: inlines, actions: actions, role: role,
                    headingLevel: headingLevel, inTable: inTable, stickerSize: stickerSize)
            } else { legacyContent }
            #else
            legacyContent
            #endif
        }
        .font(font ?? role.textFont)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var legacyContent: some View {
        Group {
            if hasMedia {
                NativeInlineLayout(revision: .init(
                    inlines: inlines, font: font ?? role.textFont,
                    dynamicType: dynamicType, stickerSize: stickerSize
                )) {
                    ForEach(Array(flowNodes.enumerated()), id: \.offset) { _, node in
                        flowPiece(node)
                    }
                }
            } else {
                Text(attributedText)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in activate(url) })
            }
        }
        .font(font ?? role.textFont)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flowNodes: [NativeInlineNode] {
        flowProjection.value(for: inlines) { NativeInlineFlow.project(inlines) }
    }

    @ViewBuilder private func flowPiece(_ node: NativeInlineNode) -> some View {
        switch node {
        case let .text(text, style): Text(styled(text, style: style))
        case let .link(text, url, style):
            if NativeRichLinkPolicy.isAllowed(url), let onLink = actions.onLink {
                Button { onLink(url) } label: { Text(styled(text, style: style)).foregroundStyle(Color.accentColor) }
                    .buttonStyle(.plain).accessibilityAddTraits(.isLink)
            } else { Text(styled(text, style: style)) }
        case let .quoteRef(name, floor, url):
            Button { actions.onQuoteReference?(name, floor, url) } label: {
                Text("@\(name) \(floor)").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(actions.onQuoteReference == nil || !NativeRichLinkPolicy.isAllowed(url))
        case let .sticker(url, alt):
            NativeRichImage(url: url, alt: alt, actions: actions)
                .frame(width: stickerSize, height: stickerSize)
        case let .image(url, alt):
            NativeRichImage(url: url, alt: alt, actions: actions)
                .frame(width: inTable ? 120 : 96, height: inTable ? 90 : 72)
        case .lineBreak:
            Text(" ").hidden().frame(width: 0).layoutValue(key: NativeLineBreakKey.self, value: true)
        }
    }

    private func styled(_ text: String, style: NativeInlineStyle) -> AttributedString {
        var value = AttributedString(text)
        var chosen = style.code ? role.codeFont : (font ?? role.textFont)
        if style.bold { chosen = chosen.bold() }
        if style.italic { chosen = chosen.italic() }
        value.font = chosen
        if style.strikethrough { value.strikethroughStyle = .single }
        if style.code { value.backgroundColor = Color.secondary.opacity(0.12) }
        return value
    }

    private var attributedText: AttributedString {
        var result = AttributedString()
        for (index, node) in inlines.enumerated() {
            var value: AttributedString
            switch node {
            case let .text(text, style): value = styled(text, style: style)
            case let .link(text, url, style):
                value = styled(text, style: style)
                if NativeRichLinkPolicy.isAllowed(url), actions.onLink != nil {
                    value.link = URL(string: "nodyssey-inline://item/\(index)")
                    value.foregroundColor = .accentColor
                }
            case let .quoteRef(name, floor, url):
                value = styled("@\(name) \(floor)", style: .init(bold: true))
                if NativeRichLinkPolicy.isAllowed(url), actions.onQuoteReference != nil {
                    value.link = URL(string: "nodyssey-inline://item/\(index)")
                    value.foregroundColor = .accentColor
                }
            case .lineBreak: value = AttributedString("\n")
            case .image, .sticker: continue // Media is rendered by the native flow branch above.
            }
            result.append(value)
        }
        return result
    }

    private func activate(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "nodyssey-inline", url.host == "item",
              let index = Int(url.lastPathComponent), inlines.indices.contains(index) else { return .discarded }
        switch inlines[index] {
        case let .link(_, raw, _):
            guard NativeRichLinkPolicy.isAllowed(raw), let action = actions.onLink else { return .discarded }
            action(raw)
        case let .quoteRef(name, floor, raw):
            guard NativeRichLinkPolicy.isAllowed(raw), let action = actions.onQuoteReference else { return .discarded }
            action(name, floor, raw)
        default: return .discarded
        }
        return .handled
    }
}

private struct NativeLineBreakKey: LayoutValueKey { static let defaultValue = false }

/// SwiftUI Text cannot contain arbitrary async image views. A native Layout is used only for
/// paragraphs containing media; text-only paragraphs keep native selection and shaping.
private struct NativeInlineLayout: Layout {
    struct Revision: Equatable {
        let inlines: [NativeInlineNode]
        let font: Font
        let dynamicType: DynamicTypeSize
        let stickerSize: Double
    }
    let revision: Revision
    typealias Cache = NativeInlineArrangementCache<Revision>

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    // SwiftUI calls this when subviews change, including their intrinsic metrics.
    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache.invalidate() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(width: bounds.width, subviews: subviews, cache: &cache)
        for index in subviews.indices {
            let frame = result.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews, cache: inout Cache) -> NativeInlineArrangement {
        cache.arrangement(width: width, revision: revision, count: subviews.count) { index, width in
            NativeInlineMeasurement(
                size: subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)),
                isLineBreak: subviews[index][NativeLineBreakKey.self]
            )
        }
    }
}
