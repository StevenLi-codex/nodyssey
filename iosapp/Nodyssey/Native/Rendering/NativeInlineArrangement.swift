import Foundation
import CoreGraphics

struct NativeInlineMeasurement {
    let size: CGSize
    let isLineBreak: Bool
}

struct NativeInlineArrangement {
    let size: CGSize
    let frames: [CGRect]
}

/// Foundation/CoreGraphics seam for the production SwiftUI media flow.
struct NativeInlineArrangementCache<Revision: Equatable> {
    private var entry: (width: CGFloat?, revision: Revision, count: Int, result: NativeInlineArrangement)?

    mutating func invalidate() { entry = nil }

    mutating func arrangement(
        width proposed: CGFloat?, revision: Revision, count: Int,
        measure: (Int, CGFloat) -> NativeInlineMeasurement
    ) -> NativeInlineArrangement {
        let width = proposed.flatMap { $0.isFinite ? max(1, $0) : nil } ?? 320
        let keyWidth: CGFloat? = proposed == nil ? nil : width
        if let entry, entry.width == keyWidth, entry.revision == revision, entry.count == count {
            return entry.result
        }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for index in 0..<count {
            let item = measure(index, width)
            let size = item.size
            if item.isLineBreak {
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
        let result = NativeInlineArrangement(
            size: CGSize(width: proposed == nil ? usedWidth : width, height: y + lineHeight), frames: frames
        )
        entry = (keyWidth, revision, count, result)
        return result
    }
}
