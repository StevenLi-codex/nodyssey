import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct AuthenticationBoundaryLifecycleTests {
    @Test func browserStartupKeepsSignInPresenterWhileRevokingPrivateOwners() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.privateBoundary") && transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", .object(["identityEpoch": .string("owner-A"), "isSignedIn": .bool(false), "generation": .integer(1)]))
        transport.emit("settings.observe", .object([:]))
        try await eventually { app.isReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        func boundary(_ phase: String, _ epoch: String, eligible: Bool = false) async throws {
            transport.emit("session.privateBoundary", boundarySnapshot(phase, epoch: epoch, confirmation: phase != "READY", recoveryEligible: eligible))
            try await eventually { app.privateBoundary.nativeString("phase") == phase && app.privateBoundary.nativeString("identityEpoch") == epoch }
        }
        try await boundary("READY", "owner-A")
        app.open("PostComposer")
        let editor = try #require(app.homePath.last)
        var revoked = false
        app.registerDismissal(destinationID: editor.id, close: { true }, revoke: { revoked = true })
        app.showSignIn()
        let presenter = try #require(app.sheet)
        let presentation = try #require(app.beginAuthenticationPresentation())
        let generation = app.generation
        // Actual beginExternalMutation emission: a fresh epoch before seed/load,
        // with recovery denied while the browser owns its cookie mutation.
        try await boundary("TRANSITIONING", "browser-transition")
        #expect(app.sheet?.id == presenter.id)
        #expect(app.homePath.isEmpty)
        #expect(revoked)
        #expect(app.generation > generation)
        #expect(!app.isPrivateReady)
        #expect(!app.canDisplay(NativeDestination("AccountSettings")))
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        // Unchanged-cookie cancellation restores the old boundary epoch only after drain.
        try await boundary("READY", "owner-A")
        #expect(app.sheet?.id == presenter.id)
        #expect(app.isPrivateReady)
        await app.dismissSheet()
        // The presentation lease lasts through the bridge's final drain, so an
        // unchanged-cookie cancel need not dismiss the underlying sign-in form.
        app.endAuthenticationPresentation(presentation)
        #expect(app.sheet == nil)
    }

    @Test(arguments: [true, false])
    func eitherCollectorOrderKeepsBrowserButActualAccountChangeClosesIt(sessionFirst: Bool) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        func session(_ epoch: String, revision: Int64 = 1) -> JSONValue {
            .object(["identityEpoch": .string(epoch), "isSignedIn": .bool(true), "generation": .integer(revision)])
        }
        func boundary(_ phase: String, _ epoch: String) async throws {
            let read = Task { await app.refreshPrivateBoundary() }
            try await eventually { transport.hasRequest("session.privateBoundary") }
            transport.resolve("session.privateBoundary", .success(boundarySnapshot(phase, epoch: epoch, confirmation: phase != "READY", recoveryEligible: false)))
            await read.value
        }
        app.session = session("owner-A")
        try await boundary("READY", "owner-A")
        app.open("Web", ["goal": .string("CHALLENGE"), "url": .string("/")])
        let presenter = try #require(app.sheet)
        _ = try #require(app.beginAuthenticationPresentation())
        if sessionFirst { app.session = session("transition") }
        try await boundary("TRANSITIONING", "transition")
        if !sessionFirst { app.session = session("transition") }
        #expect(app.sheet?.id == presenter.id)
        // UI-used predicate: signed-in challenges must not dismiss on startup.
        #expect(app.ownsAuthenticationPresentation)
        #expect(!app.isPrivateReady)
        if sessionFirst { app.session = session("owner-A") }
        try await boundary("READY", "owner-A")
        if !sessionFirst { app.session = session("owner-A") }
        #expect(app.sheet?.id == presenter.id)
        // Same signed-in flag is not identity; repository revision changes on switch.
        app.session = session("owner-B", revision: 2)
        #expect(app.sheet == nil)
        #expect(!app.ownsAuthenticationPresentation)
        #expect(!app.isPrivateReady)
    }

    @Test(arguments: ["signed-in", "unknown", "missing-session", "ended-lease"])
    func terminalOwnershipNeverRetainsAuthentication(kind: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = .object(["identityEpoch": .string("owner-A"), "isSignedIn": .bool(false), "generation": .integer(1)])
        func boundary(_ phase: String, _ epoch: String, eligible: Bool = false) async throws {
            let read = Task { await app.refreshPrivateBoundary() }
            try await eventually { transport.hasRequest("session.privateBoundary") }
            transport.resolve("session.privateBoundary", .success(boundarySnapshot(phase, epoch: epoch, confirmation: phase != "READY", recoveryEligible: eligible)))
            await read.value
        }
        try await boundary("READY", "owner-A")
        app.showSignIn()
        let token = try #require(app.beginAuthenticationPresentation())
        try await boundary("TRANSITIONING", "transition")
        #expect(app.sheet != nil)
        switch kind {
        case "signed-in": app.session = .object(["identityEpoch": .string("transition"), "isSignedIn": .bool(true), "generation": .integer(2)])
        case "missing-session": app.session = .null
        case "ended-lease":
            app.endAuthenticationPresentation(token)
            try await boundary("READY", "owner-A")
        default: try await boundary("UNKNOWN", "new-owner", eligible: true)
        }
        #expect(app.sheet == nil)
        #expect(!app.ownsAuthenticationPresentation)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func malformedBoundaryAndLateTeardownCannotKeepOrRevokeReplacementBrowser() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        func boundary(_ value: JSONValue) async throws {
            let read = Task { await app.refreshPrivateBoundary() }
            try await eventually { transport.hasRequest("session.privateBoundary") }
            transport.resolve("session.privateBoundary", .success(value))
            await read.value
        }
        try await boundary(boundarySnapshot("READY", confirmation: false))
        app.open("AccountSettings")
        #expect(app.beginAuthenticationPresentation() == nil)
        app.showSignIn()
        let old = try #require(app.beginAuthenticationPresentation())
        await app.dismissSheet()
        app.showSignIn()
        let current = try #require(app.beginAuthenticationPresentation())
        app.endAuthenticationPresentation(old)
        #expect(app.ownsAuthenticationPresentation)
        try await boundary(.null)
        #expect(app.sheet == nil)
        #expect(!app.ownsAuthenticationPresentation)
        #expect(!app.isPrivateReady)
        app.endAuthenticationPresentation(current)
    }
}
