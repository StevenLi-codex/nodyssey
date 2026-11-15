import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

/// AUTH-1: same suspended request and pre-response boundary as the independent
/// review probe, now submitted through the exact owner used by AccountSignInScreen.
@Suite @MainActor struct NativePasswordPresentationTests {
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
        let owner = AccountAuthSubmission()
        owner.form.account = "fixture"
        owner.form.password = "fixture-not-a-secret"
        owner.form.token = "fixture"
        if operation == "session.verifyTwoFactor" {
            let begun = owner.form.begin()
            let ticket = try #require(begun)
            let accepted = owner.form.acceptChallenge("fixture-challenge", ticket: ticket)
            #expect(accepted)
            owner.form.code = "123456"
        }
        owner.submit(app: app, onSigned: {})
        try await eventually { transport.hasRequest(operation) }
        transport.emit("session.privateBoundary", boundarySnapshot("TRANSITIONING", epoch: "native-auth", confirmation: true, recoveryEligible: false))
        try await eventually { app.privateBoundary.nativeString("identityEpoch") == "native-auth" }
        #expect(!app.isPrivateReady)
        #expect(transport.hasRequest(operation))
        #expect(app.sheet?.id == presenter.id, "Native form was removed before sign-in/OTP transport replied")
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        transport.resolve(operation, .success(.object(["status": .string("REFUSED")])))
        try await eventually { !owner.form.busy }
        let cleanup = owner.cancel(app: app)
        try await eventually { transport.hasRequest("session.cancelSignIn") }
        transport.resolve("session.cancelSignIn", .success(.null))
        await cleanup?.value
    }
    private func fixture() -> (ControlledTransport, NativeAppModel, AccountAuthSubmission) {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = .object(["identityEpoch": .string("guest"), "isSignedIn": .bool(false), "generation": .integer(1)])
        app.showSignIn()
        let owner = AccountAuthSubmission()
        fill(owner)
        return (transport, app, owner)
    }

    private func fill(_ owner: AccountAuthSubmission) {
        owner.form.account = "fixture"
        owner.form.password = "fixture-not-a-secret"
        owner.form.token = "fixture"
    }

    private func boundary(_ value: JSONValue, app: NativeAppModel, transport: ControlledTransport) async throws {
        let read = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(value))
        await read.value
    }

    private func finishCancel(_ owner: AccountAuthSubmission, app: NativeAppModel, transport: ControlledTransport) async throws {
        let work = owner.cancel(app: app)
        try await eventually { transport.hasRequest("session.cancelSignIn") }
        transport.resolve("session.cancelSignIn", .success(.null))
        await work?.value
    }

    @Test func passwordChallengeAndOTPFailureRetainPresenterUntilExplicitCancel() async throws {
        let (transport, app, owner) = fixture()
        let presenter = try #require(app.sheet)
        owner.submit(app: app, onSigned: { Issue.record("unexpected sign in") })
        #expect(app.ownsAuthenticationPresentation) // registration precedes Task dispatch
        try await eventually { transport.hasRequest("session.signIn") }
        transport.resolve("session.signIn", .success(.object(["status": .string("TWO_FACTOR_REQUIRED"), "challengeId": .string("otp-handle")])))
        try await eventually { owner.form.challenge != nil }
        #expect(owner.form.password.isEmpty && owner.form.token.isEmpty)
        #expect(app.ownsAuthenticationPresentation)
        try await boundary(boundarySnapshot("READY", epoch: "guest", confirmation: false), app: app, transport: transport)
        #expect(app.sheet?.id == presenter.id)
        owner.form.code = "123456"
        owner.submit(app: app, onSigned: { Issue.record("unexpected sign in") })
        try await eventually { transport.hasRequest("session.verifyTwoFactor") }
        #expect(transport.arguments(for: "session.verifyTwoFactor").last?["challengeId"] == .string("otp-handle"))
        transport.resolve("session.verifyTwoFactor", .success(.object(["status": .string("REFUSED")])))
        try await eventually { !owner.form.busy }
        #expect(owner.form.challenge == "otp-handle" && owner.form.code.isEmpty)
        #expect(owner.failure?.code == "REFUSED")
        #expect(app.ownsAuthenticationPresentation)
        try await finishCancel(owner, app: app, transport: transport)
        #expect(!app.ownsAuthenticationPresentation)
        #expect(owner.form.challenge == nil)
    }

    @Test(arguments: ["REFUSED", "NETWORK", "INVALID_CHALLENGE"])
    func errorCanRetryWithoutLosingPresenterOrLeakingTransportDetails(kind: String) async throws {
        let (transport, app, owner) = fixture()
        owner.submit(app: app, onSigned: {})
        try await eventually { transport.hasRequest("session.signIn") }
        if kind == "REFUSED" {
            transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        } else if kind == "NETWORK" {
            transport.resolve("session.signIn", .failure(NativeFailure(code: "NETWORK", message: "private transport detail")))
        } else {
            transport.resolve("session.signIn", .success(.object(["status": .string("TWO_FACTOR_REQUIRED"), "challengeId": .string("")])))
        }
        try await eventually { !owner.form.busy }
        #expect(owner.failure?.message == "")
        #expect(app.ownsAuthenticationPresentation)
        #expect(owner.form.token.isEmpty)
        owner.form.token = "retry-fixture"
        owner.submit(app: app, onSigned: {})
        try await eventually { transport.hasRequest("session.signIn") }
        transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        try await eventually { !owner.form.busy }
        try await finishCancel(owner, app: app, transport: transport)
    }

    @Test(arguments: ["cancel", "dismiss", "unknown", "malformed", "session-change"])
    func lateReplyCannotReopenOrOverwriteCancelledForm(kind: String) async throws {
        let (transport, app, owner) = fixture()
        var signed = 0
        owner.submit(app: app, onSigned: { signed += 1 })
        try await eventually { transport.hasRequest("session.signIn") }
        if kind == "dismiss" { await app.dismissSheet() }
        if kind == "unknown" {
            try await boundary(boundarySnapshot("UNKNOWN", epoch: "other", recoveryEligible: true), app: app, transport: transport)
        } else if kind == "malformed" {
            try await boundary(.null, app: app, transport: transport)
        } else if kind == "session-change" {
            app.session = .object(["identityEpoch": .string("other"), "isSignedIn": .bool(true), "generation": .integer(2)])
        }
        let cleanup = owner.cancel(app: app) // same terminal handler as UI generation/disappearance
        try await eventually { transport.hasRequest("session.cancelSignIn") }
        transport.resolve("session.cancelSignIn", .success(.null))
        // Deliberately noncooperative transport completes after cancellation.
        transport.resolve("session.signIn", .success(.object(["status": .string("TWO_FACTOR_REQUIRED"), "challengeId": .string("stale")])))
        await cleanup?.value
        #expect(owner.form.challenge == nil && !owner.form.busy && owner.failure == nil)
        #expect(signed == 0 && !app.ownsAuthenticationPresentation)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func cancelledAttemptDrainsBeforeRetryAndOldTeardownCannotEndReplacementLease() async throws {
        let (transport, app, owner) = fixture()
        owner.submit(app: app, onSigned: { Issue.record("stale success") })
        try await eventually { transport.hasRequest("session.signIn") }
        let cleanup = owner.cancel(app: app)
        try await eventually { transport.hasRequest("session.cancelSignIn") }
        fill(owner)
        owner.submit(app: app, onSigned: {})
        #expect(transport.arguments(for: "session.signIn").count == 1)
        transport.resolve("session.cancelSignIn", .success(.null))
        transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        await cleanup?.value
        try await eventually { transport.arguments(for: "session.signIn").count == 2 }
        #expect(app.ownsAuthenticationPresentation)
        transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        try await eventually { !owner.form.busy }
        let oldCleanup = owner.cancel(app: app)
        try await eventually { transport.hasRequest("session.cancelSignIn") }
        let browserLease = try #require(app.beginAuthenticationPresentation())
        transport.resolve("session.cancelSignIn", .success(.null))
        await oldCleanup?.value
        #expect(app.ownsAuthenticationPresentation)
        app.endAuthenticationPresentation(browserLease)
        #expect(!app.ownsAuthenticationPresentation)
    }

    @Test func signedSuccessEndsLeaseAndDisappearanceDoesNotCancelNewAuthentication() async throws {
        let (transport, app, owner) = fixture()
        var signed = 0
        owner.submit(app: app, onSigned: { signed += 1 })
        try await eventually { transport.hasRequest("session.signIn") }
        transport.resolve("session.signIn", .success(.object([
            "status": .string("SIGNED"), "session": app.session,
            "privateDataStatus": .string("READY"),
            "privateBoundary": boundarySnapshot("READY", epoch: "guest", confirmation: false)
        ])))
        try await eventually { signed == 1 }
        #expect(!app.ownsAuthenticationPresentation)
        #expect(!owner.form.busy && owner.form.password.isEmpty)
        let work = owner.cancel(app: app)
        await work?.value
        #expect(transport.arguments(for: "session.cancelSignIn").isEmpty)
    }

    @Test(arguments: [true, false])
    func nativeLeasePreservesOnlyPublicRootInEitherCollectorOrder(sessionFirst: Bool) async throws {
        let (transport, app, owner) = fixture()
        try await boundary(boundarySnapshot("READY", epoch: "guest", confirmation: false), app: app, transport: transport)
        app.open("PostComposer")
        let editor = try #require(app.sheetPath.last)
        var revoked = false
        app.registerDismissal(destinationID: editor.id, close: { Issue.record("must not save"); return false }, revoke: { revoked = true })
        let store = NativeStore()
        app.register(store)
        let privateRead = Task { try? await app.request("fixture.privateRead") }
        try await eventually { transport.hasRequest("fixture.privateRead") }
        let presenter = try #require(app.sheet)
        owner.submit(app: app, onSigned: {})
        try await eventually { transport.hasRequest("session.signIn") }
        let rotated = JSONValue.object(["identityEpoch": .string("native-transition"), "isSignedIn": .bool(false), "generation": .integer(1)])
        if sessionFirst { app.session = rotated }
        try await boundary(boundarySnapshot("TRANSITIONING", epoch: "native-transition", recoveryEligible: false), app: app, transport: transport)
        if !sessionFirst { app.session = rotated }
        #expect(revoked && app.sheetPath.isEmpty)
        #expect(app.sheet?.id == presenter.id && !app.isPrivateReady)
        #expect(!app.canDisplay(NativeDestination("AccountSettings")))
        transport.resolve("fixture.privateRead", .success(.null))
        let stale = await privateRead.value
        #expect(stale == nil)
        transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        try await eventually { !owner.form.busy }
        try await finishCancel(owner, app: app, transport: transport)
    }

    @Test func directRequestDoesNotReplaceExistingBrowserLease() async throws {
        let (transport, app, _) = fixture()
        let browserLease = try #require(app.beginAuthenticationPresentation())
        let request = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        transport.resolve("session.signIn", .success(.object(["status": .string("REFUSED")])))
        _ = try await request.value
        #expect(app.ownsAuthenticationPresentation)
        app.endAuthenticationPresentation(browserLease)
        #expect(!app.ownsAuthenticationPresentation)
    }

}
