import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

@Test @MainActor func replyTargetIsMetadataAndWirePrefixIsAddedExactlyOnce() async throws {
    let transport = RecordingTransport()
    let model = EditorViewModel(mode: .reply(postID: 703863), transport: transport, arguments: [
        "quotedFloor": .integer(7), "replyToAuthor": .string("ipv4"), "replyToText": .string("original")
    ])
    #expect(model.session.body.text == "")
    model.session.changeBody(EditorBuffer(text: "> editable quote\n\nanswer"))
    _ = try await model.session.submit()
    let calls = await transport.calls
    #expect(calls.first?.1["body"] == .string("> editable quote\n\nanswer"))
    #expect(calls.last?.1["body"] == .string("@ipv4 [#7](/post-703863-1#7)\n\n> editable quote\n\nanswer"))
}

@Test @MainActor func threadReplyCloseReopenKeepsTargetAndCumulativeQuotes() async throws {
    let transport = RecordingTransport()
    let owner = EditorReplyLifetime()
    await owner.open(postID: 9, transport: transport, generation: 1, arguments: ["quotedFloor": .integer(2), "replyToAuthor": .string("A")])
    let model = try #require(owner.model)
    model.session.changeBody(EditorBuffer(text: "typed"))
    #expect(await owner.hide())
    #expect(!model.isClosed)
    await owner.open(postID: 9, transport: transport, generation: 1, arguments: ["quotedFloor": .integer(4), "replyToAuthor": .string("B")])
    #expect(owner.model === model)
    #expect(model.session.body.text == "typed")
    #expect(model.session.replyContext["replyToFloor"] == .integer(4))
    await owner.open(postID: 9, transport: transport, generation: 1, arguments: ["quotedFloor": .integer(2), "replyToAuthor": .string("A"), "replyToText": .string("first\nsecond"), "postedAt": .string("2026-01-02 03:04")], quoting: true)
    await owner.open(postID: 9, transport: transport, generation: 1, arguments: ["quotedFloor": .integer(5), "replyToAuthor": .string("C"), "replyToText": .string("third")], quoting: true)
    #expect(model.session.body.text == "typed\n\n> @A [#2](/post-9-1#2) 发布于2026-01-02 03:04\n> first\n> second\n\n> @C [#5](/post-9-1#5)\n> third\n\n")
    model.clearReplyTarget()
    #expect(model.session.replyContext.isEmpty)
    #expect(model.session.body.text.contains("> @A"))
    #expect(await owner.hide())
    #expect(await transport.calls.allSatisfy { !$0.0.contains("publish") })
    owner.invalidate()
    #expect(model.isClosed)
}

@Test @MainActor func revokedThreadReplyCannotReappearAfterSuspendedHide() async throws {
    let transport = ThreadDraftGate()
    let owner = EditorReplyLifetime()
    await owner.open(postID: 4, transport: transport, generation: 1)
    let model = try #require(owner.model)
    model.session.changeBody(EditorBuffer(text: "private draft"))
    let hide = Task { await owner.hide() }
    await transport.waitForSave()
    owner.invalidate()
    await transport.finishSave()
    #expect(await hide.value == false)
    #expect(!owner.visible && model.isClosed)
    #expect(model.session.body.text.isEmpty)
}

@Test @MainActor func threadReplyRestoresRepositoryDraftThenExplicitTargetReplacesMetadataOnly() async throws {
    let transport = ThreadDraftGate(draft: .object(["body": .string("saved answer"), "replyToFloor": .integer(7), "replyToAuthor": .string("old")]))
    let owner = EditorReplyLifetime()
    await owner.open(postID: 4, transport: transport, generation: 1, arguments: ["quotedFloor": .integer(9), "replyToAuthor": .string("new")])
    let model = try #require(owner.model)
    #expect(model.session.body.text == "saved answer")
    #expect(model.session.replyContext["replyToFloor"] == .integer(9))
    #expect(model.session.pendingRestore == nil)
    owner.invalidate()
}

@Test @MainActor func initialReplyIntentSurvivesDraftFailureAndRetryExactlyOnce() async throws {
    for quoting in [false, true] {
        let transport = RetryThreadDraft()
        let owner = EditorReplyLifetime()
        await owner.open(postID: 4, transport: transport, generation: 1,
            arguments: ["quotedFloor": .integer(9), "replyToAuthor": .string("new"), "replyToText": .string("excerpt")], quoting: quoting)
        let model = try #require(owner.model)
        #expect(!model.ready)
        #expect(!owner.initialFocusAllowed)
        await owner.open(postID: 4, transport: transport, generation: 1)
        #expect(model.ready)
        #expect(!owner.initialFocusAllowed)
        if quoting {
            #expect(model.session.body.text == "saved\n\n> @new [#9](/post-4-1#9)\n> excerpt\n\n")
        } else {
            #expect(model.session.body.text == "saved")
            #expect(model.session.replyContext["replyToFloor"] == .integer(9))
        }
        let body = model.session.body.text
        await owner.open(postID: 4, transport: transport, generation: 1)
        #expect(model.session.body.text == body)
        #expect(await transport.publishes == 0)
        owner.invalidate()
    }
}

@Test func initialFocusWaitsForWindowAndNeverStealsFocusOnRetryOrPickerReturn() {
    var focus = EditorInitialFocus()
    let detached = focus.consume(attached: false, otherInputActive: false)
    let attached = focus.consume(attached: true, otherInputActive: false)
    let repeated = focus.consume(attached: true, otherInputActive: false)
    #expect(!detached && attached && !repeated)
    var interrupted = EditorInitialFocus()
    interrupted.cancel()
    let returned = interrupted.consume(attached: true, otherInputActive: false)
    #expect(!returned)
    var occupied = EditorInitialFocus()
    let busy = occupied.consume(attached: true, otherInputActive: true)
    let vacated = occupied.consume(attached: true, otherInputActive: false)
    #expect(!busy && !vacated)
}

private actor RetryThreadDraft: NativeTransport {
    var reads = 0
    var publishes = 0
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        if operation.contains("publish") { publishes += 1 }
        if operation == "draft.comment.get" {
            reads += 1
            if reads == 1 { throw NativeFailure(code: "NETWORK", message: "offline") }
            return .object(["body": .string("saved"), "replyToFloor": .integer(2)])
        }
        return .null
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}

private actor ThreadDraftGate: NativeTransport {
    let draft: JSONValue
    var save: CheckedContinuation<Void, Never>?
    init(draft: JSONValue = .null) { self.draft = draft }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        if operation == "draft.comment.get" { return draft }
        if operation == "draft.comment.save" { await withCheckedContinuation { save = $0 } }
        return .null
    }
    func waitForSave() async { while save == nil { await Task.yield() } }
    func finishSave() { save?.resume(); save = nil }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}

@Test @MainActor func acceptedThreadReplyDeletesDraftReadbacksThenReopensEmpty() async throws {
    let transport = RecordingTransport()
    let owner = EditorReplyLifetime()
    await owner.open(postID: 4, transport: transport, generation: 1)
    let model = try #require(owner.model)
    model.session.changeBody(EditorBuffer(text: "sent"))
    #expect(await owner.publish() == .null)
    #expect(!owner.visible)
    #expect(!model.isClosed)
    #expect(model.session.body.text.isEmpty)
    #expect(model.session.replyContext.isEmpty)
    let calls = await transport.calls.map(\.0)
    #expect(calls == ["draft.comment.get", "draft.comment.save", "editor.comment.publish", "draft.comment.delete", "draft.comment.get"])
    await owner.open(postID: 4, transport: transport, generation: 1)
    #expect(owner.visible)
    #expect(!model.session.accepted)
    model.invalidate()
}

@Test @MainActor func failedHideSaveKeepsThreadReplyVisibleAndRevocationNeverSaves() async throws {
    let transport = RecordingTransport(fail: true)
    let owner = EditorReplyLifetime()
    await owner.open(postID: 4, transport: transport, generation: 1)
    let model = try #require(owner.model)
    #expect(!(await owner.hide()))
    #expect(owner.visible)
    #expect(!model.isClosed)
    owner.invalidate()
    #expect(await transport.calls.map(\.0) == ["draft.comment.get"])
}
