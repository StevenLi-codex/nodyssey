import Testing
@testable import AccountBehavior

@Test func relativeReadmeLinksKeepActiveSiteAndQuoteFloor() {
    #expect(AccountLinkState.resolve("/post-42/2", origin: "https://www.deepflood.com", floor: "19") == "https://www.deepflood.com/post-42/2#19")
    #expect(AccountLinkState.resolve("https://example.com/post#4", origin: "https://www.nodeseek.com", floor: "7") == "https://example.com/post#4")
    #expect(AccountLinkState.resolve("//attacker.example/path", origin: "https://www.nodeseek.com") == nil)
    #expect(AccountLinkState.resolve("javascript:alert(1)", origin: "https://www.nodeseek.com") == nil)
}
