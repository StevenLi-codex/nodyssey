import Foundation
import Testing
@testable import NativeRendering

@Test func inlineFlowPreservesWhitespaceNewlinesAndGraphemes() {
    let text = "hello  world\n中文 👩🏽‍💻 e\u{301}\tend"
    let tokens = NativeInlineFlow.tokens(text)
    #expect(tokens.joined() == text)
    #expect(tokens.contains("\n"))
    #expect(tokens.contains("中"))
    #expect(tokens.contains("文"))
    #expect(tokens.contains("👩🏽‍💻"))
    #expect(tokens.contains("e\u{301}"))
    #expect(tokens.contains("hello"))
    #expect(tokens.contains("world"))
    #expect(NativeInlineFlow.tokens("") == [])
}
