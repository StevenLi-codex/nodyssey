import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

/// Replays the production NativeBridge.sessionMutation pre-dispatch boundary
/// emission into the actual app coordinator. No credentials or server requests.
@Suite @MainActor struct IndependentNativeLoginReview {
    @Test(arguments: ["session.signIn", "session.verifyTwoFactor"])
    func nativeAuthenticationMustKeepItsFormDuringOwnPreResponseTransition(operation: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.privateBoundary") && transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", .object(["identityEpoch": .string("guest"), "isSignedIn": .bool(false), "generation": .integer(1)]))
        transport.emit("settings.observe", .object([:]))
        transport.emit("session.privateBoundary", boundarySnapshot("READY", epoch: "guest", confirmation: false, recoveryEligible: false))
        try await eventually { app.isReady && app.isPrivateReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        app.showSignIn()
        let presenter = try #require(app.sheet)
        // AccountSignInScreen.submit calls request directly; unlike browser it
        // does not call beginAuthenticationPresentation().
        let request = Task { try await app.request(operation) }
        try await eventually { transport.hasRequest(operation) }
        transport.emit("session.privateBoundary", boundarySnapshot("TRANSITIONING", epoch: "native-auth", confirmation: true, recoveryEligible: false))
        try await eventually { app.privateBoundary.nativeString("identityEpoch") == "native-auth" }
        #expect(!app.isPrivateReady)
        #expect(transport.hasRequest(operation))
        #expect(app.sheet?.id == presenter.id, "Native form was removed before sign-in/OTP transport replied")
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        transport.resolve(operation, .success(.object(["status": .string("REFUSED")])))
        _ = try await request.value
    }
}
