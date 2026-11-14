import SwiftUI

/// UI-only callbacks. Owners perform navigation, fetch live poll state, and confirm payments.
/// A nil callback disables its action; the renderer never fabricates a successful mutation.
struct NativeRichTextActions {
    var onImage: ((String, String?) -> Void)?
    var onVote: ((Int64) -> Void)?
    var onStardust: ((NativeStardustReceive) -> Void)?
    var onLink: ((String) -> Void)?
    var onQuoteReference: ((_ name: String, _ floor: String, _ url: String) -> Void)?
    var onCode: ((NativeCode, NativeCodeAction) -> Void)?

    init(
        onImage: ((String, String?) -> Void)? = nil,
        onVote: ((Int64) -> Void)? = nil,
        onStardust: ((NativeStardustReceive) -> Void)? = nil,
        onLink: ((String) -> Void)? = nil,
        onQuoteReference: ((_ name: String, _ floor: String, _ url: String) -> Void)? = nil,
        onCode: ((NativeCode, NativeCodeAction) -> Void)? = nil
    ) {
        self.onImage = onImage
        self.onVote = onVote
        self.onStardust = onStardust
        self.onLink = onLink
        self.onQuoteReference = onQuoteReference
        self.onCode = onCode
    }
}

enum NativeCodeAction { case adaptedReport, source, compare }

/// Native content for posts, replies, signatures, Readmes, messages, and previews.
/// Decode [NativeRichNode] directly using JSONDecoder; no HTML/JavaScript is involved.
struct NativeRichTextView: View {
    let nodes: [NativeRichNode]
    var actions: NativeRichTextActions

    init(nodes: [NativeRichNode], actions: NativeRichTextActions = .init()) {
        self.nodes = nodes
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(nodes.indices, id: \.self) { index in
                NativeRichBlock(node: nodes[index], actions: actions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NativeRichBlock: View {
    let node: NativeRichNode
    let actions: NativeRichTextActions

    @ViewBuilder var body: some View {
        switch node {
        case .paragraph(let inlines):
            NativeInlineContent(inlines: inlines, actions: actions)
        case let .heading(level, inlines):
            NativeInlineContent(inlines: inlines, actions: actions, font: headingFont(level))
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
                Text("\(receive.amount) Stardust").font(.headline)
                if !receive.description.isEmpty { Text(receive.description).textSelection(.enabled) }
                Text("Member #\(String(receive.memberId)) · Reference #\(String(receive.refId))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if receive.onetime { Text("One payment per account").font(.caption) }
                Button("Review payment") { actions.onStardust?(receive) }
                    .disabled(actions.onStardust == nil)
            }
            .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case .code(let code):
            NativeCodeBlock(code: code, actions: actions)
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

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.bold()
        case 4: .title3.bold()
        default: .headline
        }
    }
}

private struct NativeRichFold: View {
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
        DisclosureGroup(isExpanded: $expanded) {
            AnyView(NativeRichTextView(nodes: children, actions: actions)).padding(.top, 8)
        } label: {
            if title.isEmpty { Text("Details") } else { Text(title) }
        }
    }
}

private struct NativeRichTabs: View {
    let tabs: [NativeRichTab]
    let actions: NativeRichTextActions
    @State private var selected = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(tabs.indices, id: \.self) { index in
                        Button { selected = index } label: {
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
                        .frame(height: selected == index ? nil : 0, alignment: .top)
                        .clipped()
                        .opacity(selected == index ? 1 : 0)
                        .allowsHitTesting(selected == index)
                        .accessibilityHidden(selected != index)
                }
            }
        }
        .onChange(of: tabs.count) { count in
            if selected >= count { selected = 0 }
        }
    }
}

private struct NativeRichImage: View {
    let url: String
    let alt: String?
    let actions: NativeRichTextActions

    @ViewBuilder var body: some View {
        if NativeRichLinkPolicy.isAllowed(url) {
            // The platform image already owns tap-to-view, retry, and metered-data consent.
            // Do not wrap it in a Button: that steals retry gestures or opens two galleries.
            NativeRemoteImage(url: url, aspectFit: true)
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
    let inlines: [NativeInlineNode]
    let actions: NativeRichTextActions
    var font: Font = .body
    var inTable = false
    @ScaledMetric(relativeTo: .body) private var stickerSize = 24.0

    private var hasMedia: Bool {
        inlines.contains { node in
            switch node { case .image, .sticker: true; default: false }
        }
    }

    var body: some View {
        Group {
            if hasMedia {
                NativeInlineLayout {
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
        .font(font)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var flowNodes: [NativeInlineNode] {
        inlines.flatMap { node -> [NativeInlineNode] in
            switch node {
            case let .text(text, style): return NativeInlineFlow.tokens(text).map { $0.contains("\n") || $0.contains("\r") ? .lineBreak : .text($0, style) }
            case let .link(text, url, style): return NativeInlineFlow.tokens(text).map { $0.contains("\n") || $0.contains("\r") ? .lineBreak : .link($0, url, style) }
            default: return [node]
            }
        }
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
        var chosen = style.code ? Font.system(.body, design: .monospaced) : font
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
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for index in subviews.indices {
            let frame = result.frames[index]
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width proposed: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = proposed.flatMap { $0.isFinite ? max(1, $0) : nil } ?? 320
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if view[NativeLineBreakKey.self] {
                frames.append(CGRect(x: x, y: y, width: 0, height: size.height))
                y += max(lineHeight, size.height)
                x = 0
                lineHeight = 0
                continue
            }
            if x > 0 && x + size.width > width {
                y += lineHeight
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width
            usedWidth = max(usedWidth, x)
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: proposed == nil ? usedWidth : width, height: y + lineHeight), frames)
    }
}
