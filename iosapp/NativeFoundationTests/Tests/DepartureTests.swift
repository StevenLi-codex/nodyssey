import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

@Suite @MainActor struct DepartureTests {
    @Test func sheetReplacementAndOuterCloseAwaitRegisteredEditorRefusal() async throws {
        let app = NativeAppModel(transport: IdleTransport())
        app.showSignIn()
        app.open("PostComposer")
        let editor = try #require(app.sheetPath.last)
        var closes = 0
        var revoked = false
        _ = app.registerDismissal(destinationID: editor.id, close: { closes += 1; return false }, revoke: { revoked = true })
        let sheet = app.sheet
        app.open("Web", ["goal": .string("CHALLENGE")])
        try await eventually { closes == 1 }
        #expect(app.sheet == sheet)
        #expect(app.sheetPath.last == editor)
        await app.dismissSheet()
        #expect(closes == 2)
        #expect(app.sheetPath.last == editor)
        #expect(!revoked)
    }

    @Test func identityRevokesWithoutCallingNormalCloseAndStaleHandlerCannotUnregisterReplacement() async throws {
        let app = NativeAppModel(transport: IdleTransport())
        app.session = boundarySession()
        app.open("PostComposer")
        let editor = try #require(app.homePath.last)
        var closeCount = 0
        var revocations = 0
        let old = app.registerDismissal(destinationID: editor.id, close: { closeCount += 1; return true }, revoke: { revocations += 1 })
        let current = app.registerDismissal(destinationID: editor.id, close: { closeCount += 1; return true }, revoke: { revocations += 1 })
        #expect(current != old)
        app.unregisterDismissal(destinationID: editor.id, token: old)
        app.session = boundarySession(.string("process-B"))
        #expect(closeCount == 0)
        #expect(revocations == 2) // Replaced owner and active owner both revoked.
        #expect(app.homePath.isEmpty)
    }

    @Test func staleCloseCannotRemoveNewNavigationAndTemporaryPushDoesNotClose() async throws {
        let app = NativeAppModel(transport: IdleTransport())
        app.open("PostComposer")
        let editor = try #require(app.homePath.last)
        var continuation: CheckedContinuation<Bool, Never>?
        var closes = 0
        _ = app.registerDismissal(destinationID: editor.id, close: {
            closes += 1
            return await withCheckedContinuation { continuation = $0 }
        }, revoke: {})
        app.open("Settings")
        #expect(closes == 0)
        app.selectedTab = .profile
        #expect(closes == 0)
        let reset = Task { await app.resetNavigationAwaitingDeparture() }
        try await eventually { continuation != nil }
        app.open("Help")
        continuation?.resume(returning: true)
        await reset.value
        #expect(app.profilePath.last?.route == "Help")
        #expect(app.homePath.contains(editor))
    }
}
