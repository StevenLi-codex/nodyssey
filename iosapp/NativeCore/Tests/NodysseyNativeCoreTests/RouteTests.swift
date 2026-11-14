import Testing
@testable import NodysseyNativeCore

struct RouteTests {
    @Test func canonicalLinksPreserveIdentityAndPage() {
        #expect(NativeDeepLink.parse("https://www.nodeseek.com/post-9007199254740993-2") == .post(id: 9007199254740993, page: 2))
        #expect(NativeDeepLink.parse("http://NODESEEK.COM/post-42") == .post(id: 42, page: 1))
        #expect(NativeDeepLink.parse("https://nodeseek.com/space/9223372036854775807") == .space(uid: Int64.max))
        #expect(NativeDeepLink.parse("https://nodeseek.com/member?t=%E7%94%A8%E6%88%B7") == .member(name: "用户"))
        #expect(NativeDeepLink.parse("https://nodeseek.com/notification#/atMe") == .notifications(group: .mentions))
        #expect(NativeDeepLink.parse("https://nodeseek.com/notification#/message?mode=talk&to=9007199254740993") == .messageThread(uid: 9007199254740993))
        #expect(NativeDeepLink.parse("https://nodeseek.com/notification#/message") == .notifications(group: .messages))
        #expect(NativeDeepLink.parse("https://nodeseek.com/notification#/unknown") == .notifications(group: nil))
        #expect(NativeDeepLink.parse("https://nodeseek.com/jump?to=https%3A%2F%2Fnodeseek.com%2Fpost-42-2") == .post(id: 42, page: 2))
    }

    @Test func untrustedOrAmbiguousLinksNeverBecomeNativeIdentities() {
        for url in [
            "https://nodeseek.com.evil.test/post-1", "https://evilnodeseek.com/post-1",
            "https://user@nodeseek.com/post-1", "https://nodeseek.com:444/post-1",
            "javascript://nodeseek.com/post-1", "https://evil.test/?next=https://nodeseek.com/post-1",
            "https://nodeseek.com/search?q=/post-1", "https://nodeseek.com/a/post-1",
            "https://nodeseek.com/post-1-suffix", "https://nodeseek.com/post-1-0",
            "https://nodeseek.com/post-0", "https://nodeseek.com/post-9223372036854775808",
            "https://nodeseek.com/post-1-99999999999999999999999999",
            "https://nodeseek.com/space/-1", "https://nodeseek.com/%70ost-1",
            "https://nodeseek.com/space/1%2F2", "https://nodeseek.com/member?t=a&t=b",
            "https://nodeseek.com/jump?to=https://evil.test/post-1",
            "https://nodeseek.com/post-1\n", "https://nodeseek.com\\@evil.test/post-1",
        ] {
            #expect(NativeDeepLink.parse(url) == nil, "Rejected URL: \(url)")
        }
    }

    @Test func encodedAuthorityCannotAliasTheAllowedSite() {
        #expect(NativeDeepLink.parse("https://%6eodeseek.com/post-1") == nil)
        #expect(NativeDeepLink.parse("https://nodeseek%2ecom/post-1") == nil)
    }

    @Test func sameNumericIDOnAnotherSiteIsNotTheSameDestination() {
        #expect(NativeDeepLink.parse("https://deepflood.com/post-42") == nil)
        #expect(NativeDeepLink.parse("https://nodeseek.com/post-42", site: .deepFlood) == nil)
        #expect(NativeDeepLink.parse("https://www.deepflood.com/post-42-3", site: .deepFlood) == .post(id: 42, page: 3))
    }
}
