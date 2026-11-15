import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct LoginAdmissionTests {
    @Test(arguments: ["session.signIn", "session.verifyTwoFactor"])
    func successfulAuthenticationConsumesFinalPrivateBoundary(operation: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { try await app.request(operation) }
        try await eventually { transport.hasRequest(operation) }
        transport.resolve(operation, .success(.object([
            "status": .string("SIGNED"), "session": boundarySession(),
            "privateDataStatus": .string("READY"),
            "privateBoundary": boundarySnapshot("READY", confirmation: false)
        ])))
        let result = try await task.value
        #expect(result.nativeString("status") == "SIGNED")
        #expect(app.isSignedIn)
        // The auth payload must not wait for a possibly delayed boundary collector.
        #expect(app.isPrivateReady)
        #expect(app.canDisplay(NativeDestination("AccountSettings")))
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test(arguments: ["CONFIRMATION_REQUIRED", "MISSING", "CONTRADICTORY"])
    func signedAuthenticationNeverAdoptsUnverifiedDataOrBecomesLoginFailure(status: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        var fields: [String: JSONValue] = ["status": .string("SIGNED"), "session": boundarySession()]
        if status != "MISSING" {
            fields["privateDataStatus"] = .string(status == "CONTRADICTORY" ? "READY" : status)
            fields["privateBoundary"] = boundarySnapshot()
        }
        transport.resolve("session.signIn", .success(.object(fields)))
        let result = try await task.value
        #expect(result.nativeString("status") == "SIGNED")
        #expect(app.isSignedIn)
        #expect(!app.isPrivateReady)
        #expect(!app.canDisplay(NativeDestination("AccountSettings")))
        #expect(app.privateResetConfirmation == nil)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        if status == "CONFIRMATION_REQUIRED" { #expect(app.canConfirmPrivateReset) }
        else { #expect(app.privateBoundaryFailure?.code == "INVALID_DATA") }
    }

    @Test func newerBoundaryReadWinsOverLateSignedReadyPayload() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        let auth = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        let read = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot()))
        await read.value
        transport.resolve("session.signIn", .success(.object([
            "status": .string("SIGNED"), "session": boundarySession(),
            "privateDataStatus": .string("READY"), "privateBoundary": boundarySnapshot("READY", confirmation: false)
        ])))
        _ = try await auth.value
        #expect(app.isSignedIn)
        #expect(!app.isPrivateReady)
        #expect(app.privateBoundary.nativeString("phase") == "UNKNOWN")
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }
}
