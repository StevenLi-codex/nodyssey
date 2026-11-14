import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Plain source remains available even when the report parser cannot adapt this block.
/// NodeQuality/YABS parsing and persisted comparison baskets belong to the injected owner.
struct NativeCodeBlock: View {
    let code: NativeCode
    var actions: NativeRichTextActions = .init()
    @State private var showingSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let language = code.language, !language.isEmpty {
                    Text(language).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { copySource() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .labelStyle(.iconOnly).accessibilityLabel("Copy code")
                Button {
                    if let onCode = actions.onCode { onCode(code, .source) }
                    else { showingSource = true }
                } label: { Label("Full source", systemImage: "arrow.up.left.and.arrow.down.right") }
                .labelStyle(.iconOnly).accessibilityLabel("Full source")
                if let onCode = actions.onCode {
                    Menu {
                        Button("Adapted report") { onCode(code, .adaptedReport) }
                        Button("Add to report comparison") { onCode(code, .compare) }
                    } label: { Label("Report", systemImage: "chart.bar.doc.horizontal") }
                }
            }
            NativeAnsiText(code: code)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingSource) {
            NavigationStack {
                ScrollView(.vertical) { NativeAnsiText(code: code).padding() }
                    .navigationTitle(code.language ?? "Source")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSource = false }
                        }
                        ToolbarItem(placement: .automatic) {
                            Button("Copy") { copySource() }
                        }
                    }
            }
        }
    }

    private func copySource() {
        #if canImport(UIKit)
        UIPasteboard.general.string = code.code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.code, forType: .string)
        #endif
    }
}

private struct NativeAnsiText: View {
    let code: NativeCode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal) {
            Text(attributedCode)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var attributedCode: AttributedString {
        var text = AttributedString(code.code)
        text.font = .system(.body, design: .monospaced)
        for span in code.spans {
            guard let range = span.attributedRange(in: text) else { continue }
            // Apply in wire order: overlapping spans have deterministic last-run precedence.
            text[range].font = .system(.body, design: .monospaced).weight(span.bold ? .bold : .regular)
            text[range].underlineStyle = span.underline ? .single : nil
            text[range].foregroundColor = palette(span.fg)
            text[range].backgroundColor = palette(span.bg)
        }
        return text
    }

    private func palette(_ index: Int?) -> Color? {
        guard let index, (0..<16).contains(index) else { return nil }
        // Theme-aware ANSI palette; indices are canonical 0–15, not packed RGB values.
        let dark: [Color] = [.init(white: 0.18), .red, .green, .yellow, .blue, .purple, .cyan, .init(white: 0.85), .gray, .pink, .mint, .init(red: 1, green: 0.9, blue: 0.4), .init(red: 0.5, green: 0.7, blue: 1), .init(red: 0.9, green: 0.6, blue: 1), .init(red: 0.5, green: 1, blue: 1), .white]
        let light: [Color] = [.black, .init(red: 0.7, green: 0.1, blue: 0.1), .init(red: 0.1, green: 0.45, blue: 0.15), .init(red: 0.55, green: 0.4, blue: 0), .blue, .purple, .init(red: 0, green: 0.4, blue: 0.45), .gray, .init(white: 0.35), .red, .init(red: 0, green: 0.55, blue: 0.2), .init(red: 0.65, green: 0.5, blue: 0), .init(red: 0.2, green: 0.35, blue: 0.85), .init(red: 0.65, green: 0.2, blue: 0.7), .init(red: 0, green: 0.5, blue: 0.6), .init(white: 0.8)]
        return (colorScheme == .dark ? dark : light)[index]
    }
}
