import Foundation
import Testing
@testable import NativeRendering

@Test func ansiOffsetsAreUTF16NotCharacters() throws {
    let source = "A😀中e\u{301}Z"
    let emoji = NativeAnsiSpan(start: 1, end: 3, fg: 10)
    let cjk = NativeAnsiSpan(start: 3, end: 4)
    let accent = NativeAnsiSpan(start: 5, end: 6, underline: true)
    #expect(String(source[try #require(emoji.range(in: source))]) == "😀")
    #expect(String(source[try #require(cjk.range(in: source))]) == "中")
    let scalarRange = try #require(accent.range(in: source))
    #expect(Array(source[scalarRange].unicodeScalars).map(\.value) == [0x301])
    // This is the conversion used by the SwiftUI code renderer, including combining boundaries.
    let attributed = AttributedString(source)
    let attributedRange = try #require(accent.attributedRange(in: attributed))
    let attributedScalars = attributed[attributedRange].unicodeScalars.map { $0.value }
    #expect(attributedScalars == [0x301])
}

@Test func ansiRejectsBrokenSurrogatesAndInvalidBoundsWithoutChangingText() {
    let source = "A😀B"
    for (start, end) in [(-1, 1), (0, 8), (3, 2), (1, 1), (2, 3), (1, 2), (Int.min, Int.max)] {
        #expect(NativeAnsiSpan(start: start, end: end).range(in: source) == nil)
    }
    #expect(NativeAnsiSpan(start: 0, end: 4).range(in: source) != nil)
    #expect(NativeAnsiSpan(start: 0, end: 1).range(in: "") == nil)
}

@Test func ansiHandlesZWJFlagsAndVariationSelectorsAtScalarBoundaries() throws {
    let source = "👩🏽‍💻🇨🇳✈️"
    // Kotlin lengths: woman=2, skin tone=2, ZWJ=1, laptop=2, each flag letter=2.
    let ranges = [(0, 7, "👩🏽‍💻"), (7, 11, "🇨🇳"), (11, 13, "✈️"), (4, 5, "\u{200D}")]
    for (start, end, expected) in ranges {
        let range = try #require(NativeAnsiSpan(start: start, end: end).range(in: source))
        #expect(String(source[range]) == expected)
    }
}
