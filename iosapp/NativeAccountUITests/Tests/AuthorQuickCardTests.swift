import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

/// Controlled callbacks exercise the production state/transport, never a live forum.
@MainActor private final class AuthorCardFixture {
    var calls: [(operation: String, arguments: JSONValue, reply: @Sendable (String) -> Void)] = []
    var cancellations = 0
    var transport: CallbackNativeTransport {
        CallbackNativeTransport(request: { [self] operation, arguments, reply in
            calls.append((operation, try! JSONDecoder().decode(JSONValue.self, from: Data(arguments.utf8)), reply))
            return NativeCancellation { Task { @MainActor in self.cancellations += 1 } }
        }, observe: { _, _, _ in
            Issue.record("Quick cards must not subscribe or poll")
            return NativeCancellation {}
        })
    }
    func reply(_ index: Int, _ data: JSONValue) {
        let envelope = JSONValue.object(["ok": .bool(true), "data": data])
        calls[index].reply(String(decoding: try! JSONEncoder().encode(envelope), as: UTF8.self))
    }
    func profile(_ uid: Int64) -> JSONValue { .object(["uid": .integer(uid), "name": .string("Synthetic author")]) }
}

@Test @MainActor func authorCardNavigationRequiresCurrentIdentityAndMessageAuthentication() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    var generation = 1
    #expect(card.navigation(for: 71, message: false, signedIn: true) == nil)
    let task = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { generation }) }
    await eventually { fixture.calls.count == 1 }
    fixture.reply(0, fixture.profile(71))
    await eventually { fixture.calls.count == 2 }
    fixture.reply(1, .array([])); await task.value
    #expect(card.navigation(for: 71, message: false, signedIn: false) == .route("UserSpace", ["uid": .integer(71)]))
    #expect(card.navigation(for: 71, message: true, signedIn: false) == .signIn)
    #expect(card.navigation(for: 71, message: true, signedIn: true) == .route("MessageThread", ["uid": .integer(71), "userName": .string("Synthetic author")]))
    #expect(card.navigation(for: 72, message: false, signedIn: true) == nil)
    generation = 2
    #expect(card.navigation(for: 71, message: true, signedIn: true) == nil)
    #expect(card.snapshot(for: 71).profile == nil)
    #expect(fixture.calls.count == 2)
}

@Test @MainActor func authorCardUIDReplacementFencesLateProfileAndOldCleanup() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    let first = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    #expect(card.snapshot(for: 72).profile == nil)
    let second = Task { await card.load(uid: 72, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 2 }
    fixture.reply(0, fixture.profile(71)); first.cancel(); await first.value
    #expect(card.snapshot(for: 72).isLoading)
    fixture.reply(1, fixture.profile(72))
    await eventually { fixture.calls.count == 3 }
    fixture.reply(2, .array([])); await second.value
    #expect(card.snapshot(for: 71).profile == nil)
    #expect(card.snapshot(for: 72).profile?["uid"]?.int == 72)
}

@Test @MainActor func authorCardSessionChangeDuringNotesHidesProfileAndPrivateNoteImmediately() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    var generation = 1
    let task = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { generation }) }
    await eventually { fixture.calls.count == 1 }
    fixture.reply(0, fixture.profile(71))
    await eventually { fixture.calls.count == 2 }
    #expect(card.snapshot(for: 71).profile != nil)
    generation = 2
    #expect(card.snapshot(for: 71).profile == nil)
    fixture.reply(1, .array([.object(["uid": .integer(71), "note": .string("Private old session")])]))
    await task.value
    #expect(card.snapshot(for: 71).note == nil)
    #expect(card.snapshot(for: 71).profile == nil)
    #expect(fixture.calls.count == 2)
}

@Test @MainActor func authorCardFailureRetriesReadOnlyAndNotesFailureDoesNotDiscardProfile() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    let first = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    fixture.calls[0].reply(#"{"ok":false,"error":{"code":"NETWORK","message":""}}"#)
    await first.value
    #expect(card.snapshot(for: 71).failure?.code == "NETWORK")
    #expect(card.snapshot(for: 71).profile == nil && !card.snapshot(for: 71).isLoading)
    #expect(fixture.calls.count == 1)
    let retry = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 2 }
    #expect(card.snapshot(for: 71).failure == nil)
    fixture.reply(1, fixture.profile(71))
    await eventually { fixture.calls.count == 3 }
    fixture.calls[2].reply(#"{"ok":false,"error":{"code":"NETWORK","message":""}}"#)
    await retry.value
    #expect(card.snapshot(for: 71).profile?["uid"]?.int == 71)
    #expect(!card.snapshot(for: 71).notesAvailable && card.snapshot(for: 71).note == nil)
    #expect(fixture.calls.map(\.operation) == ["profile.user", "profile.user", "notes.get"])
}

@Test @MainActor func authorCardInvalidUIDAndMismatchedDTOCannotLoadNotesOrNavigate() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    await card.load(uid: 0, using: fixture.transport, currentGeneration: { 1 })
    #expect(fixture.calls.isEmpty)
    #expect(card.snapshot(for: 0).failure?.code == "INVALID_ARGUMENT")
    let task = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    fixture.reply(0, fixture.profile(72)); await task.value
    #expect(card.snapshot(for: 71).failure?.code == "INVALID_RESPONSE")
    #expect(card.navigation(for: 71, message: false, signedIn: true) == nil)
    #expect(fixture.calls.count == 1)
}

@Test @MainActor func authorCardMissingNameDoesNotInventMessageRecipient() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    let task = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    fixture.reply(0, .object(["uid": .integer(71)]))
    await eventually { fixture.calls.count == 2 }
    fixture.reply(1, .array([])); await task.value
    #expect(card.navigation(for: 71, message: true, signedIn: true) == nil)
    #expect(card.navigation(for: 71, message: false, signedIn: true) == .route("UserSpace", ["uid": .integer(71)]))
    #expect(card.snapshot(for: 71).notesAvailable && card.snapshot(for: 71).note == nil)
}

@Test @MainActor func authorCardCancellationClearsLoadingAndRejectsLateData() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    let task = Task { await card.load(uid: 71, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    task.cancel(); await task.value
    fixture.reply(0, fixture.profile(71))
    #expect(!card.snapshot(for: 71).isLoading)
    #expect(card.snapshot(for: 71).profile == nil)
    #expect(card.snapshot(for: 71).failure == nil)
    #expect(fixture.calls.count == 1)
}

@Test @MainActor func authorCardLoadsExactUIDThenExistingNotesWithoutInventedCounts() async {
    let fixture = AuthorCardFixture()
    let card = AccountAuthorQuickCardState()
    let task = Task { await card.load(uid: 9_007_199_254_740_993, using: fixture.transport, currentGeneration: { 1 }) }
    await eventually { fixture.calls.count == 1 }
    #expect(card.snapshot(for: 9_007_199_254_740_993).isLoading)
    #expect(fixture.calls[0].operation == "profile.user")
    #expect(fixture.calls[0].arguments == .object(["uid": .integer(9_007_199_254_740_993)]))
    fixture.reply(0, fixture.profile(9_007_199_254_740_993))
    await eventually { fixture.calls.count == 2 }
    #expect(fixture.calls[1].operation == "notes.get")
    #expect(fixture.calls[1].arguments == .object([:]))
    fixture.reply(1, .array([
        .object(["uid": .integer(12), "note": .string("Not this author")]),
        .object(["uid": .integer(9_007_199_254_740_993), "note": .string("My actual note")])
    ]))
    await task.value
    let result = card.snapshot(for: 9_007_199_254_740_993)
    #expect(!result.isLoading && result.failure == nil)
    #expect(result.profile?["uid"]?.int == 9_007_199_254_740_993)
    #expect(result.profile?["topicCount"] == nil && result.profile?["rank"] == nil)
    #expect(result.note == "My actual note" && result.notesAvailable)
    #expect(fixture.calls.count == 2)
}
