import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

func workspaceBoundary(_ phase: String = "UNKNOWN", epoch: String = "process-A", capable: Bool = true) -> JSONValue {
    var fields = boundarySnapshot(phase, epoch: epoch, confirmation: phase != "READY").object!
    fields["canCreateWorkspace"] = .bool(capable)
    fields["workspaceBinding"] = .string(phase == "READY" ? "SESSION_PROOF" : "LEGACY")
    fields["preservedData"] = .bool(phase == "READY")
    return .object(fields)
}

@Suite @MainActor struct PrivateWorkspaceTests {
    private func display(_ snapshot: JSONValue, app: NativeAppModel, transport: ControlledTransport) async throws {
        let read = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(snapshot))
        await read.value
    }

    @Test func explicitWorkspaceCreationReadsBackAndReconcilesSessionWithoutReset() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        #expect(app.canCreatePrivateWorkspace)
        app.beginPrivateWorkspaceConfirmation()
        let confirmation = try #require(app.privateWorkspaceConfirmation)
        #expect(transport.arguments(for: "session.createPrivateWorkspace").isEmpty)
        let action = Task { await app.confirmPrivateWorkspace(confirmation) }
        try await eventually { transport.hasRequest("session.createPrivateWorkspace") }
        #expect(transport.arguments(for: "session.createPrivateWorkspace") == [["confirmed": .bool(true), "identityEpoch": .string("process-A")]])
        #expect(!app.isPrivateReady)
        let ready = workspaceBoundary("READY", epoch: "workspace-B", capable: false)
        transport.resolve("session.createPrivateWorkspace", .success(ready))
        try await eventually { transport.hasRequest("session.privateBoundary") }
        #expect(!app.isPrivateReady)
        transport.resolve("session.privateBoundary", .success(ready))
        try await eventually { transport.hasRequest("session.sync") }
        #expect(!app.isPrivateReady)
        transport.resolve("session.sync", .success(boundarySession(.string("workspace-B"))))
        await action.value
        #expect(app.isSignedIn && app.isPrivateReady)
        #expect(app.canDisplay(NativeDestination("PostComposer")))
        #expect(app.privateBoundary.nativeString("workspaceBinding") == "SESSION_PROOF")
        #expect(app.privateBoundary.nativeBool("preservedData") == true)
        #expect(app.privateBoundaryFailure == nil)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        await app.confirmPrivateWorkspace(confirmation)
        #expect(transport.arguments(for: "session.createPrivateWorkspace").count == 1)
    }

    @Test func inFlightAuthenticationRevokesAnAlreadyDisplayedConfirmation() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        let auth = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        #expect(!app.canCreatePrivateWorkspace)
        #expect(app.privateWorkspaceConfirmation == nil)
        // Do not dispatch a stale intent even after auth finishes at the same epoch.
        transport.resolve("session.signIn", .success(.object([
            "status": .string("SIGNED"), "session": boundarySession(),
            "privateDataStatus": .string("CONFIRMATION_REQUIRED"), "privateBoundary": workspaceBoundary()
        ])))
        let result = try await auth.value
        #expect(result.nativeString("status") == "SIGNED")
        #expect(app.isSignedIn && !app.isPrivateReady)
        #expect(app.canCreatePrivateWorkspace)
        let action = Task { await app.confirmPrivateWorkspace(token) }
        for _ in 0..<40 { await Task.yield() }
        if transport.hasRequest("session.createPrivateWorkspace") {
            transport.resolve("session.createPrivateWorkspace", .failure(NativeFailure(code: "UNEXPECTED", message: "unexpected dispatch")))
        }
        await action.value
        #expect(transport.arguments(for: "session.createPrivateWorkspace").isEmpty)
    }

    @Test(arguments: ["decline", "epoch", "capability", "browser", "cancelled-task"])
    func invalidatedConfirmationNeverDispatches(reason: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        switch reason {
        case "decline": app.cancelPrivateWorkspaceConfirmation()
        case "epoch":
            app.session = boundarySession(.string("new-session"))
            app.session = boundarySession()
        case "capability":
            try await display(workspaceBoundary(capable: false), app: app, transport: transport)
            #expect(app.privateWorkspaceConfirmation == nil)
            try await display(workspaceBoundary(), app: app, transport: transport)
        case "browser":
            app.open("Web", ["goal": .string("EXTERNAL"), "url": .string("https://example.com")])
            #expect(!app.canCreatePrivateWorkspace)
            #expect(app.privateWorkspaceConfirmation == nil)
        default: break
        }
        let action = Task { await app.confirmPrivateWorkspace(token) }
        if reason == "cancelled-task" { action.cancel() }
        for _ in 0..<40 { await Task.yield() }
        if transport.hasRequest("session.createPrivateWorkspace") {
            transport.resolve("session.createPrivateWorkspace", .failure(NativeFailure(code: "UNEXPECTED", message: "unexpected")))
        }
        await action.value
        #expect(transport.arguments(for: "session.createPrivateWorkspace").isEmpty)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test(arguments: ["missing", "false", "unsigned"])
    func unsupportedOrUnsignedCannotOfferWorkspace(kind: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = kind == "unsigned" ? .object(["isSignedIn": .bool(false), "identityEpoch": .string("process-A"), "generation": .integer(1)]) : boundarySession()
        let snapshot = kind == "missing" ? boundarySnapshot() : workspaceBoundary(capable: kind != "false")
        try await display(snapshot, app: app, transport: transport)
        #expect(!app.canCreatePrivateWorkspace)
        #expect(app.privateBoundaryFailure == nil)
        app.beginPrivateWorkspaceConfirmation()
        #expect(app.privateWorkspaceConfirmation == nil)
    }

    @Test(arguments: ["STALE_EPOCH", "ACTIVE_MUTATION", "INVALID_DATA"])
    func refusedActivationDoesNotTurnAuthenticationIntoFailure(code: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        let action = Task { await app.confirmPrivateWorkspace(token) }
        try await eventually { transport.hasRequest("session.createPrivateWorkspace") }
        transport.resolve("session.createPrivateWorkspace", .failure(NativeFailure(code: code, message: "private proof")))
        await action.value
        #expect(app.isSignedIn && !app.isPrivateReady)
        #expect(app.privateBoundaryFailure?.code == code)
        #expect(app.privateBoundaryFailure?.message != "private proof")
        #expect(!app.privateWorkspaceRunning)
        #expect(app.privateWorkspaceConfirmation == nil)
        #expect(!transport.hasRequest("session.sync"))
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test(arguments: ["same-epoch", "binding", "preserved", "confirmation", "null"])
    func incompleteOrContradictorySuccessNeverAdmitsPrivateUI(kind: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        let action = Task { await app.confirmPrivateWorkspace(token) }
        try await eventually { transport.hasRequest("session.createPrivateWorkspace") }
        var fields = workspaceBoundary("READY", epoch: "workspace-B", capable: false).object!
        switch kind {
        case "same-epoch": fields["identityEpoch"] = .string("process-A")
        case "binding": fields["workspaceBinding"] = .string("LEGACY")
        case "preserved": fields["preservedData"] = .bool(false)
        case "confirmation": fields["requiresConfirmation"] = .bool(true)
        default: break
        }
        transport.resolve("session.createPrivateWorkspace", .success(kind == "null" ? .null : .object(fields)))
        await action.value
        #expect(!app.isPrivateReady && app.isSignedIn)
        #expect(app.privateBoundaryFailure?.code == "INVALID_DATA")
        #expect(!transport.hasRequest("session.sync"))
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func genericRequestCannotBypassWorkspaceConfirmation() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        do {
            _ = try await app.request("session.createPrivateWorkspace", ["confirmed": .bool(true), "identityEpoch": .string("process-A")])
            Issue.record("Missing confirmation admitted")
        } catch { #expect((error as? NativeFailure)?.code == "CONFIRMATION_REQUIRED") }
        #expect(transport.arguments(for: "session.createPrivateWorkspace").isEmpty)
    }

    @Test(arguments: ["no-observation", "collectors-first"])
    func activationRevokesStoresEditorsAndLateCallbacks(order: String) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        let store = NativeStore()
        let observer = Task { await store.observe(app, "profile.self") }
        defer { observer.cancel() }
        try await eventually { transport.hasStream("profile.self") }
        transport.emit("profile.self", .string("old private data"))
        try await eventually { store.value == .string("old private data") }
        app.open("PostComposer")
        let editor = try #require(app.homePath.last)
        var revoked = false
        var saved = false
        app.registerDismissal(destinationID: editor.id, close: { saved = true; return true }, revoke: { revoked = true })
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        let action = Task { await app.confirmPrivateWorkspace(token) }
        try await eventually { transport.hasRequest("session.createPrivateWorkspace") }
        if order == "collectors-first" {
            // The retired graph has its own transition epoch; the newly built
            // graph will publish a different epoch. Neither is an account ID.
            app.session = boundarySession(.string("retired-transition"))
            try await display(boundarySnapshot("TRANSITIONING", epoch: "retired-transition", recoveryEligible: false), app: app, transport: transport)
        }
        let ready = workspaceBoundary("READY", epoch: "workspace-B", capable: false)
        transport.resolve("session.createPrivateWorkspace", .success(ready))
        try await eventually { transport.hasRequest("session.privateBoundary") || !app.privateWorkspaceRunning }
        if transport.hasRequest("session.privateBoundary") {
            transport.resolve("session.privateBoundary", .success(ready))
            try await eventually { transport.hasRequest("session.sync") }
            transport.resolve("session.sync", .success(boundarySession(.string("workspace-B"))))
        }
        await action.value
        #expect(app.isPrivateReady)
        #expect(revoked && !saved)
        #expect(app.homePath.isEmpty)
        #expect(store.value == .null)
        transport.emit("profile.self", .string("late private data"))
        await observer.value
        #expect(store.value == .null)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func mismatchedReadbackNeverUnlocksOrStartsSessionSync() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary(), app: app, transport: transport)
        app.beginPrivateWorkspaceConfirmation()
        let token = try #require(app.privateWorkspaceConfirmation)
        let action = Task { await app.confirmPrivateWorkspace(token) }
        try await eventually { transport.hasRequest("session.createPrivateWorkspace") }
        transport.resolve("session.createPrivateWorkspace", .success(workspaceBoundary("READY", epoch: "workspace-B", capable: false)))
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(workspaceBoundary("READY", epoch: "unrelated-C", capable: false)))
        await action.value
        #expect(!app.isPrivateReady && app.isSignedIn)
        #expect(app.privateBoundaryFailure?.code == "INVALID_DATA")
        #expect(!transport.hasRequest("session.sync"))
    }

    @Test func contradictoryReadyWorkspaceCapabilityFailsClosed() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        try await display(workspaceBoundary("READY"), app: app, transport: transport)
        #expect(!app.isPrivateReady)
        #expect(app.privateBoundaryFailure?.code == "INVALID_DATA")
    }
}
