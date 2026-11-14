import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// Network-free, read-only export. A source URL is always visible, never a hidden metadata field.
struct FloorShareCard: View {
    let document: FloorShareDocument
    let dark: Bool
    private var copy: FloorShareCopy { .init(language: document.language) }
    private var foreground: Color { dark ? .white : Color(red: 0.08, green: 0.09, blue: 0.12) }
    private var secondary: Color { dark ? Color(white: 0.78) : Color(white: 0.30) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: document.author).font(.system(size: 17, weight: .semibold))
                    if let date = document.createdAt { Text(verbatim: date).font(.system(size: 12)).foregroundStyle(secondary) }
                }
                Spacer(minLength: 8)
                Text(verbatim: document.floor).font(.system(size: 14, weight: .semibold)).foregroundStyle(secondary)
            }
            Rectangle().fill(secondary.opacity(0.3)).frame(height: 1)
            Text(verbatim: document.body).font(.system(size: 16)).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if document.truncated { Text(verbatim: copy.truncated).font(.system(size: 12, weight: .medium)).foregroundStyle(secondary) }
            Rectangle().fill(secondary.opacity(0.3)).frame(height: 1)
            Text(verbatim: document.title).font(.system(size: 15, weight: .semibold))
            Text(verbatim: document.source.absoluteString).font(.system(size: 12)).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: copy.disclosure).font(.system(size: 11)).foregroundStyle(secondary)
            Text("Nodyssey").font(.system(size: 13, weight: .semibold)).foregroundStyle(secondary)
        }
        .foregroundStyle(foreground)
        .padding(24)
        .frame(width: 390, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(dark ? Color(red: 0.09, green: 0.10, blue: 0.13) : .white)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.dynamicTypeSize, .large)
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct FloorShareRendered {
    let document: FloorShareDocument
    let png: Data
}

@MainActor enum FloorShareRenderer {
    /// iOS 16 ImageRenderer; no UIKit hierarchy, web view, remote loader, or screenshot of live UI.
    /// Measure before rasterization, reduce whole graphemes until the full card fits, then export
    /// the exact reduced document used by the preview. Never silently clip the attribution footer.
    static func render(_ document: FloorShareDocument, dark: Bool) throws -> FloorShareRendered {
        var fitted = document
        for _ in 0..<16 {
            let renderer = ImageRenderer(content: FloorShareCard(document: fitted, dark: dark))
            renderer.proposedSize = ProposedViewSize(width: 390, height: nil)
            renderer.scale = 2
            renderer.isOpaque = true
            var size = CGSize.zero
            renderer.render { measured, _ in size = measured }
            guard size.width > 0, size.height > 0, size.height.isFinite else { throw FloorShareError.renderFailed }
            if size.height <= 2000 {
                guard let image = renderer.cgImage else { throw FloorShareError.renderFailed }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw FloorShareError.renderFailed }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw FloorShareError.renderFailed }
                return FloorShareRendered(document: fitted, png: data as Data)
            }
            guard !fitted.body.isEmpty else { throw FloorShareError.renderFailed }
            fitted = FloorShareDocument(author: fitted.author, floor: fitted.floor, title: fitted.title,
                                        createdAt: fitted.createdAt, source: fitted.source,
                                        body: String(fitted.body.prefix(fitted.body.count / 2)),
                                        truncated: true, language: fitted.language)
        }
        throw FloorShareError.renderFailed
    }
}
