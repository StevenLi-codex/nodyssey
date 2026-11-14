import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

let testSite: JSONValue = .object([
    "current": .string("DEEPFLOOD"), "selected": .string("DEEPFLOOD"), "requiresRestart": .bool(false),
    "sites": .array([.object(["id": .string("DEEPFLOOD"), "origin": .string("https://www.deepflood.com"), "displayName": .string("DeepFlood")])])
])

@Suite @MainActor struct LifecycleTests {
    @Test func rootCancellationRevokesReadiness() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { await app.start() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", .object(["identityEpoch": .string("process-A"), "isSignedIn": .bool(true), "generation": .integer(1)]))
        transport.emit("settings.observe", .object([:]))
        try await eventually { app.isReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        task.cancel()
        await task.value
        #expect(!app.isReady)
        #expect(app.session == .null)
    }
    @Test func restartWaitsForCancelledOwnerInsteadOfLosingSubscription() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let first = Task { await app.start() }
        try await eventually { transport.hasRequest("site.get") }
        first.cancel()
        let second = Task { await app.start() }
        for _ in 0..<20 { await Task.yield() }
        transport.resolve("site.get", .success(testSite))
        await first.value
        try await eventually { transport.hasRequest("site.get") }
        second.cancel()
        transport.resolve("site.get", .success(testSite))
        await second.value
    }
    @Test func sessionObservationFailureRevokesReadyContent() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { await app.start() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", .object(["identityEpoch": .string("process-A"), "isSignedIn": .bool(true), "generation": .integer(1)]))
        transport.emit("settings.observe", .object([:]))
        try await eventually { app.isReady && transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .success(.null))
        app.open("AccountSettings")
        transport.finish("session.state", error: NativeFailure(code: "NETWORK", message: "secret"))
        await task.value
        #expect(!app.isReady)
        #expect(app.session == .null)
        #expect(app.homePath.isEmpty)
        #expect(app.lifecycleFailure?.message != "secret")
    }
    @Test func lateAuthenticationSnapshotCannotDowngradeNewerSession() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { try await app.request("session.signIn") }
        try await eventually { transport.hasRequest("session.signIn") }
        app.session = .object(["isSignedIn": .bool(false), "generation": .integer(9)])
        transport.resolve("session.signIn", .success(.object(["session": .object(["isSignedIn": .bool(true), "generation": .integer(8)])])))
        do { _ = try await task.value; Issue.record("Superseded sign-in reported success") }
        catch { #expect((error as? NativeFailure)?.code == "SIGN_IN_SUPERSEDED") }
        #expect(!app.isSignedIn)
        #expect(app.session.nativeInt("generation") == 9)
    }
    @Test func delayedMutationResultCannotCrossAccountBoundary() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let task = Task { try await app.request("account.saveProfileFields") }
        try await eventually { transport.hasRequest("account.saveProfileFields") }
        app.session = .object(["isSignedIn": .bool(false), "generation": .integer(3)])
        transport.resolve("account.saveProfileFields", .success(.object([:])))
        do { _ = try await task.value; Issue.record("Stale mutation reported success") }
        catch { #expect((error as? NativeFailure)?.code == "SESSION_CHANGED") }
    }

    @Test func startupQueuesDeepLinkUntilSiteAndSessionReadyAndReportsForegroundFailure() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        app.openLink("https://www.deepflood.com/post-9223372036854775807-3#8")
        #expect(app.homePath.isEmpty)
        let task = Task { await app.start() }
        try await eventually { transport.hasRequest("site.get") }
        transport.resolve("site.get", .success(testSite))
        try await eventually { transport.hasStream("session.state") && transport.hasStream("settings.observe") }
        transport.emit("session.state", .object(["identityEpoch": .string("process-A"), "isSignedIn": .bool(false), "generation": .integer(1)]))
        transport.emit("settings.observe", .object(["appLanguage": .string("ENGLISH")]))
        try await eventually { app.isReady }
        #expect(app.homePath.last?.route == "PostDetail")
        #expect(app.homePath.last?.arguments["postId"] == .integer(Int64.max))
        #expect(app.homePath.last?.arguments["page"] == .integer(3))
        #expect(app.homePath.last?.arguments["floor"] == .string("8"))
        try await eventually { transport.hasRequest("app.foreground") }
        transport.resolve("app.foreground", .failure(NativeFailure(code: "NETWORK", message: "private details")))
        try await eventually { app.lifecycleFailure != nil }
        #expect(app.lifecycleFailure?.code == "NETWORK")
        task.cancel()
        await task.value
    }
}
