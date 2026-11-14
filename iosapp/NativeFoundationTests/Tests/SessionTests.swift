import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

/// Synthetic transport never contacts a server; tests execute production model/state.
struct IdleTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue { .null }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { _ in }
    }
}

@Suite @MainActor struct SessionTests {
    @Test func clearanceOnlyUpdateDoesNotDiscardDraftNavigation() {
        let app = NativeAppModel(transport: IdleTransport())
        app.session = .object(["identityEpoch": .string("opaque-A"), "isSignedIn": .bool(true), "generation": .integer(1), "hasClearance": .bool(false)])
        app.open("PostComposer")
        let path = app.homePath
        app.selectedTab = .profile
        app.open("Settings")
        let profilePath = app.profilePath
        app.open("Web", ["goal": .string("CHALLENGE")])
        let sheet = app.sheet
        let generation = app.generation
        // SessionRepository.sync increments its reload generation for clearance
        // changes even when the account fingerprint and sign-in status are stable.
        app.session = .object(["identityEpoch": .string("opaque-A"), "isSignedIn": .bool(true), "generation": .integer(2), "hasClearance": .bool(true)])
        #expect(app.homePath == path)
        #expect(app.profilePath == profilePath)
        #expect(app.sheet == sheet)
        #expect(app.selectedTab == .profile)
        #expect(app.generation == generation)
    }

    @Test func accountEpochChangeClearsEveryBackStackAndSheetEvenWithSameReloadRevision() {
        let app = NativeAppModel(transport: IdleTransport())
        app.session = .object(["identityEpoch": .string("opaque-A"), "isSignedIn": .bool(true), "generation": .integer(1)])
        app.open("PostDetail", ["postId": .integer(Int64.max)])
        app.selectedTab = .notifications
        app.open("MessageThread", ["uid": .integer(42)])
        app.selectedTab = .profile
        app.open("AccountSettings")
        app.showSignIn()
        let before = app.generation
        app.session = .object(["identityEpoch": .string("opaque-B"), "isSignedIn": .bool(true), "generation": .integer(1)])
        #expect(app.homePath.isEmpty)
        #expect(app.notificationsPath.isEmpty)
        #expect(app.profilePath.isEmpty)
        #expect(app.sheet == nil)
        #expect(app.generation > before)
    }
}
