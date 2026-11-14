import Foundation
import Testing
@testable import NativeRendering

@Test func linkPolicyRejectsExecutableSchemesAndAmbiguousURLs() {
    for url in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "file:///private/a", "vbscript:x", "//evil.example/x", "https://user:password@example.org", "https:", " https://example.org", "https://exa\nmple.org", "\\evil.example", "custom:thing"] {
        #expect(!NativeRichLinkPolicy.isAllowed(url))
    }
    for url in ["https://example.org/post/1#3", "http://example.org", "mailto:person@example.org", "/post/1#3", "#3"] {
        #expect(NativeRichLinkPolicy.isAllowed(url))
    }
    #expect(!NativeRichLinkPolicy.isAllowed("mailto:"))
    #expect(!NativeRichLinkPolicy.isAllowed(""))
}
