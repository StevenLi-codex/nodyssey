import Foundation
import Testing
@testable import NativeRendering

@Test @MainActor func mixedInlineProjectionPreservesActionsMediaAndGraphemesOnReuse() {
    let style = NativeInlineStyle(bold: true, italic: true, strikethrough: true, code: true)
    let input: [NativeInlineNode] = [
        .text("中文 👩🏽‍💻\r\n", style),
        .link("hello world", "/post-1-1#2", style),
        .sticker(url: "/animated.gif", alt: "motion"),
        .image(url: "/image.png", alt: nil),
        .quoteRef(name: "member", floor: "#2", url: "/post-1-1"), .lineBreak,
    ]
    let expected: [NativeInlineNode] = [
        .text("中", style), .text("文", style), .text(" ", style),
        .text("👩🏽‍💻", style), .lineBreak,
        .link("hello", "/post-1-1#2", style), .link(" ", "/post-1-1#2", style),
        .link("world", "/post-1-1#2", style),
        .sticker(url: "/animated.gif", alt: "motion"),
        .image(url: "/image.png", alt: nil),
        .quoteRef(name: "member", floor: "#2", url: "/post-1-1"), .lineBreak,
    ]
    let memo = NativeRenderingMemo<[NativeInlineNode], [NativeInlineNode]>()
    var projections = 0
    func project(_ nodes: [NativeInlineNode]) -> [NativeInlineNode] {
        memo.value(for: nodes) {
            projections += 1
            return NativeInlineFlow.project(nodes)
        }
    }
    #expect(project(input) == expected)
    #expect(project(input) == expected)
    #expect(projections == 1)
    let replacement: [NativeInlineNode] = [.link("new", "#9", .init()), input[2]]
    #expect(project(replacement) == replacement)
    #expect(projections == 2)
}
