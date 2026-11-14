import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct RoutingTests {
    @Test func crossSiteIdentityNeverBecomesNativeRoute() {
        let destination = NativeLinkRouting.destination("https://www.nodeseek.com/post-42-1", site: .deepFlood)
        #expect(destination.route == "Web")
        #expect(destination.arguments["goal"] == .string("EXTERNAL"))
        #expect(destination.arguments["postId"] == nil)
    }
    @Test func dangerousAddressesAreRejectedBeforeBeingQueued() {
        let app = NativeAppModel(transport: IdleTransport())
        for value in ["javascript:alert(1)", "https://user:password@nodeseek.com/post-42", "https://nodeseek.com\\@evil.example/post-42", "file:///private/data"] {
            app.openLink(value)
            #expect(app.linkFailure?.code == "INVALID_LINK")
            #expect(app.homePath.isEmpty)
        }
    }
    @Test func nextLaunchSelectionDoesNotChangeCurrentIdentityOrDestroyNavigation() throws {
        let app = NativeAppModel(transport: IdleTransport())
        try app.applySite(testSite)
        app.open("PostDetail", ["postId": .integer(44)])
        let path = app.homePath
        var next = testSite.object!
        next["selected"] = .string("NODESEEK")
        next["requiresRestart"] = .bool(true)
        try app.applySite(.object(next))
        #expect(app.activeSite == .deepFlood)
        #expect(app.homePath == path)
        next["current"] = .string("NODESEEK")
        try app.applySite(.object(next))
        #expect(app.homePath.isEmpty)
    }
    @Test func authenticationAndChallengeOfferDifferentRecoveryWithoutRetryingMutation() {
        #expect(NativeFailurePresentation(code: "LOGIN_REQUIRED").recovery == .signIn)
        #expect(NativeFailurePresentation(code: "SESSION_UNRECOGNISED").recovery == .signIn)
        #expect(NativeFailurePresentation(code: "CHALLENGE").recovery == .challenge)
        #expect(NativeFailurePresentation(code: "UNSUPPORTED").recovery == .none)
        #expect(NativeFailurePresentation(code: "INTERNAL").recovery == .retry)
    }
}
