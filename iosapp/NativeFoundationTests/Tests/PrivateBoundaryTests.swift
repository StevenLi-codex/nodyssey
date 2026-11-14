import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

func boundarySession(_ epoch: JSONValue = .string("process-A"), generation: Int64 = 1) -> JSONValue {
    .object(["identityEpoch": epoch, "isSignedIn": .bool(true), "generation": .integer(generation), "hasClearance": .bool(false)])
}
func boundarySnapshot(_ phase: String = "UNKNOWN", epoch: String = "process-A", confirmation: Bool = true, recoveryEligible: Bool? = nil) -> JSONValue {
    .object(["phase": .string(phase), "identityEpoch": .string(epoch), "requiresConfirmation": .bool(confirmation),
             "recoveryEligible": .bool(recoveryEligible ?? (phase == "UNKNOWN"))])
}

@Suite @MainActor struct PrivateBoundaryTests {
    @Test func interruptedTransitionOffersOnlyDrainedDisplayedEpochRecovery() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        func display(_ eligible: Bool, epoch: String = "process-A") async throws {
            let read = Task { await app.refreshPrivateBoundary() }
            try await eventually { transport.hasRequest("session.privateBoundary") }
            transport.resolve("session.privateBoundary", .success(boundarySnapshot("TRANSITIONING", epoch: epoch, recoveryEligible: eligible)))
            await read.value
        }
        try await display(false)
        #expect(!app.canConfirmPrivateReset)
        app.beginPrivateResetConfirmation()
        #expect(app.privateResetConfirmation == nil)
        #expect(!app.isPrivateReady)
        try await display(true)
        // This is the predicate used by the recovery view's review-reset button.
        #expect(app.canConfirmPrivateReset)
        app.beginPrivateResetConfirmation()
        let stale = try #require(app.privateResetConfirmation)
        try await display(false)
        #expect(!app.canConfirmPrivateReset)
        #expect(app.privateResetConfirmation == nil)
        try await display(true)
        await app.confirmPrivateReset(stale)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        app.beginPrivateResetConfirmation()
        let cancelled = try #require(app.privateResetConfirmation)
        app.cancelPrivateResetConfirmation()
        await app.confirmPrivateReset(cancelled)
        app.beginPrivateResetConfirmation()
        let oldEpoch = try #require(app.privateResetConfirmation)
        try await display(true, epoch: "interrupted-reopen")
        await app.confirmPrivateReset(oldEpoch)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        app.beginPrivateResetConfirmation()
        let confirmation = try #require(app.privateResetConfirmation)
        let cancelledTask = Task { await app.confirmPrivateReset(confirmation) }
        cancelledTask.cancel()
        await cancelledTask.value
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        let reset = Task { await app.confirmPrivateReset(confirmation) }
        try await eventually { transport.hasRequest("session.resetPrivateStores") }
        #expect(transport.arguments(for: "session.resetPrivateStores") == [["confirmed": .bool(true), "identityEpoch": .string("interrupted-reopen")]])
        #expect(!app.canConfirmPrivateReset)
        #expect(!app.isPrivateReady)
        transport.resolve("session.resetPrivateStores", .success(.null))
        try await eventually { transport.hasRequest("session.privateBoundary") }
        #expect(!app.isPrivateReady)
        transport.resolve("session.privateBoundary", .success(boundarySnapshot("READY", epoch: "reset-ready", confirmation: false)))
        await reset.value
        #expect(!app.isPrivateReady) // Session must independently catch up to the reset epoch.
        app.session = boundarySession(.string("reset-ready"))
        #expect(app.isPrivateReady)
        await app.confirmPrivateReset(confirmation)
        #expect(transport.arguments(for: "session.resetPrivateStores").count == 1)
    }

    @Test(arguments: [JSONValue.null, .integer(1), .string("true")])
    func malformedRecoveryEligibilityCannotKeepConfirmation(_ malformed: JSONValue) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        try await prepareUnknown(app, transport)
        app.beginPrivateResetConfirmation()
        let confirmation = try #require(app.privateResetConfirmation)
        var fields = try #require(boundarySnapshot("TRANSITIONING", recoveryEligible: true).object)
        if malformed == .null { fields.removeValue(forKey: "recoveryEligible") }
        else { fields["recoveryEligible"] = malformed }
        let read = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(.object(fields)))
        await read.value
        #expect(app.privateBoundary == .null)
        #expect(app.privateBoundaryFailure?.code == "INVALID_DATA")
        #expect(!app.canConfirmPrivateReset)
        #expect(app.privateResetConfirmation == nil)
        await app.confirmPrivateReset(confirmation)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func lateAuthenticationCannotReinstallDifferentEpochAtEqualReloadRevision() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        let auth = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        app.session = boundarySession(.string("process-B"))
        transport.resolve("session.signIn", .success(.object(["status": .string("SIGNED"), "session": boundarySession()])))
        do { _ = try await auth.value; Issue.record("Old identity reinstalled at equal reload revision") }
        catch { #expect((error as? NativeFailure)?.code == "SIGN_IN_SUPERSEDED") }
        #expect(app.session.nativeString("identityEpoch") == "process-B")
    }

    @Test func cancelledConfirmationTaskNeverDispatchesAndAccountChangeSuppressesLateResetReply() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        try await prepareUnknown(app, transport)
        app.beginPrivateResetConfirmation()
        let confirmation = try #require(app.privateResetConfirmation)
        let cancelled = Task { await app.confirmPrivateReset(confirmation) }
        cancelled.cancel()
        await cancelled.value
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        let reset = Task { await app.confirmPrivateReset(confirmation) }
        try await eventually { transport.hasRequest("session.resetPrivateStores") }
        app.session = boundarySession(.string("process-B"))
        transport.resolve("session.resetPrivateStores", .success(.null))
        await reset.value
        #expect(app.session.nativeString("identityEpoch") == "process-B")
        #expect(!app.isPrivateReady)
        #expect(!transport.hasRequest("session.privateBoundary"))
        #expect(app.privateResetConfirmation == nil)
    }

    @Test func missingObservedEpochClearsSessionButPublicRecoveryStaysAvailable() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.privateBoundary") && transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", boundarySession())
        transport.emit("settings.observe", .object([:]))
        transport.emit("session.privateBoundary", boundarySnapshot("READY", confirmation: false))
        try await eventually { app.isPrivateReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        app.open("PostComposer")
        let generation = app.generation
        transport.emit("session.state", .object(["isSignedIn": .bool(true), "generation": .integer(2)]))
        try await eventually { app.generation > generation }
        #expect(app.session == .null)
        #expect(!app.isPrivateReady)
        #expect(app.isReady)
        #expect(app.homePath.isEmpty)
        app.open("Settings")
        #expect(app.homePath.last?.route == "Settings")
        root.cancel()
        await root.value
    }

    @Test func unknownBoundaryGatesPrivateFactoriesButNotPublicRecovery() {
        let app = NativeAppModel(transport: IdleTransport())
        for route in ["Profile", "PostComposer", "MessageThread", "Bookmarks", "AccountSettings", "Notifications", "UnrecognisedRoute"] {
            #expect(!app.canDisplay(NativeDestination(route)))
        }
        for route in ["Settings", "Help", "Privacy", "SignIn", "ThemeSettings"] {
            #expect(app.canDisplay(NativeDestination(route)))
        }
        #expect(app.canDisplay(NativeDestination("Web", ["goal": .string("CHALLENGE")])))
        #expect(!app.canDisplay(NativeDestination("Web", ["goal": .string("TELEGRAM_BIND")])))
    }

    private func prepareUnknown(_ app: NativeAppModel, _ transport: ControlledTransport) async throws {
        app.session = boundarySession()
        let task = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot()))
        await task.value
    }

    @Test func cancelledOrStaleDialogCannotResetEvenAfterReturningToSameEpoch() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        try await prepareUnknown(app, transport)
        app.beginPrivateResetConfirmation()
        let cancelled = try #require(app.privateResetConfirmation)
        app.cancelPrivateResetConfirmation()
        await app.confirmPrivateReset(cancelled)
        app.beginPrivateResetConfirmation()
        let stale = try #require(app.privateResetConfirmation)
        app.session = boundarySession(.string("process-B"))
        app.session = boundarySession()
        await app.confirmPrivateReset(stale)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        #expect(!app.isPrivateReady)
    }

    @Test func failedResetRemainsClosedAndNeedsAnotherExplicitConfirmation() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        try await prepareUnknown(app, transport)
        app.beginPrivateResetConfirmation()
        let confirmation = try #require(app.privateResetConfirmation)
        let task = Task { await app.confirmPrivateReset(confirmation) }
        try await eventually { transport.hasRequest("session.resetPrivateStores") }
        transport.resolve("session.resetPrivateStores", .failure(NativeFailure(code: "RESET_FAILED", message: "private proof not for display")))
        await task.value
        #expect(!app.isPrivateReady)
        #expect(app.privateResetConfirmation == nil)
        #expect(app.privateBoundaryFailure?.code == "RESET_FAILED")
        #expect(app.privateBoundaryFailure?.message != "private proof not for display")
        await app.confirmPrivateReset(confirmation)
        #expect(transport.arguments(for: "session.resetPrivateStores").count == 1)
    }

    @Test func runningSiteChangeCannotReuseOldReadyBoundary() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        try app.applySite(testSite)
        app.session = boundarySession()
        let refresh = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot("READY", confirmation: false)))
        await refresh.value
        #expect(app.isPrivateReady)
        try app.applySite(.object(["current": .string("NODESEEK")]))
        #expect(!app.isPrivateReady)
        #expect(app.session == .null)
    }

    @Test(arguments: [JSONValue.null, .integer(42), .string("")])
    func malformedEpochAuthenticationCannotBeAdopted(_ epoch: JSONValue) async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        app.open("PostComposer")
        let task = Task { try await app.request("session.sync") }
        try await eventually { transport.hasRequest("session.sync") }
        transport.resolve("session.sync", .success(boundarySession(epoch, generation: 2)))
        do { _ = try await task.value; Issue.record("Malformed epoch adopted") }
        catch { #expect((error as? NativeFailure)?.code == "INVALID_DATA") }
        #expect(app.session == .null)
        #expect(app.homePath.isEmpty)
        #expect(!app.isPrivateReady)
    }

    @Test func explicitRecoveryUsesDisplayedEpochOnceAndReadsBackBeforeAdmission() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.session = boundarySession()
        let refresh = Task { await app.refreshPrivateBoundary() }
        try await eventually { transport.hasRequest("session.privateBoundary") }
        transport.resolve("session.privateBoundary", .success(boundarySnapshot()))
        await refresh.value
        #expect(!app.isPrivateReady)
        app.beginPrivateResetConfirmation()
        let confirmation = try #require(app.privateResetConfirmation)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        let reset = Task { await app.confirmPrivateReset(confirmation) }
        try await eventually { transport.hasRequest("session.resetPrivateStores") }
        #expect(transport.arguments(for: "session.resetPrivateStores") == [["confirmed": .bool(true), "identityEpoch": .string("process-A")]])
        #expect(!app.isPrivateReady)
        transport.resolve("session.resetPrivateStores", .success(.null))
        try await eventually { transport.hasRequest("session.privateBoundary") }
        #expect(!app.isPrivateReady)
        transport.resolve("session.privateBoundary", .success(boundarySnapshot("READY", confirmation: false)))
        await reset.value
        #expect(app.isPrivateReady)
        #expect(app.privateResetConfirmation == nil)
        await app.confirmPrivateReset(confirmation)
        #expect(transport.arguments(for: "session.resetPrivateStores").count == 1)
    }

    @Test func genericRequestCannotSupplyAutomaticDestructiveConfirmation() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { try await app.request("session.resetPrivateStores", ["confirmed": .bool(true), "identityEpoch": .string("process-A")]) }
        // Complete an incorrectly admitted call so a regression cannot hang the suite.
        for _ in 0..<30 { await Task.yield() }
        if transport.hasRequest("session.resetPrivateStores") { transport.resolve("session.resetPrivateStores", .success(.null)) }
        do { _ = try await task.value; Issue.record("Automatic destructive confirmation was admitted") }
        catch { #expect((error as? NativeFailure)?.code == "CONFIRMATION_REQUIRED") }
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
    }

    @Test func boundaryRevocationClearsPrivateUIBeforeSessionStreamCatchesUp() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.privateBoundary") && transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", boundarySession())
        transport.emit("settings.observe", .object([:]))
        transport.emit("session.privateBoundary", boundarySnapshot("READY", confirmation: false))
        try await eventually { app.privateBoundary.nativeString("phase") == "READY" && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        app.open("PostComposer")
        app.showSignIn()
        let generation = app.generation
        transport.emit("session.privateBoundary", boundarySnapshot(epoch: "process-B"))
        try await eventually { app.privateBoundary.nativeString("identityEpoch") == "process-B" }
        #expect(app.homePath.isEmpty)
        #expect(app.sheet == nil)
        #expect(app.generation > generation)
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        root.cancel()
        await root.value
    }

    @Test func emptyInstallationCanOpenPublicSettingsBeforeSessionInitialization() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.privateBoundary") && transport.hasStream("settings.observe") && transport.hasStream("session.state") }
        transport.emit("session.state", .null)
        transport.emit("settings.observe", .object(["onboardingSeen": .bool(false)]))
        transport.emit("session.privateBoundary", boundarySnapshot("TRANSITIONING", confirmation: false))
        try await eventually { app.settings.object != nil && app.privateBoundary.object != nil }
        #expect(app.isReady)
        app.open("Settings")
        #expect(app.homePath.last?.route == "Settings")
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        if transport.hasRequest("app.foreground") { transport.resolve("app.foreground", .success(.null)) }
        root.cancel()
        await root.value
    }

    @Test func initialUnknownBoundarySubscribesWithoutResetAndAllowsPublicNavigation() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let root = Task { await app.start() }
        defer { root.cancel() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("settings.observe") && transport.hasStream("session.state") }
        transport.emit("session.state", boundarySession())
        transport.emit("settings.observe", .object(["onboardingSeen": .bool(true)]))
        try await eventually { app.isReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        #expect(transport.hasStream("session.privateBoundary"))
        transport.emit("session.privateBoundary", boundarySnapshot())
        app.open("Settings")
        #expect(app.homePath.last?.route == "Settings")
        app.showSignIn()
        #expect(app.sheet?.route == "SignIn")
        #expect(transport.arguments(for: "session.resetPrivateStores").isEmpty)
        root.cancel()
        await root.value
    }
}
