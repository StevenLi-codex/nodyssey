import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

@Test func removingQuoteKeepsBodyAndSelectionAndProtectsModifiedQuote() {
    var buffer = EditorBuffer(text: "> 原文\n\n新回复", selection: NSRange(location: 9, length: 0))
    buffer.removePrefixIfUnchanged("> 原文\n\n")
    #expect(buffer.text == "新回复")
    #expect(buffer.selection == NSRange(location: 3, length: 0))
    var edited = EditorBuffer(text: "> 已修改\n\n新回复")
    edited.removePrefixIfUnchanged("> 原文\n\n")
    #expect(edited.text == "> 已修改\n\n新回复")
}

@Test @MainActor func typingBeforeLoadStartsIsNotOverwritten() async throws {
    let transport = SuspendedTransport()
    let editor = EditorSession(mode: .edit(postID: 4, commentID: 5, page: 1, opening: true), transport: transport)
    editor.changeBody(EditorBuffer(text: "打开后立刻输入"))
    let load = Task { try await editor.load() }
    await transport.waitForCall()
    await transport.finish(.object(["body": .string("服务器旧正文")]))
    try await load.value
    #expect(editor.body.text == "打开后立刻输入")
    #expect(editor.pendingRestore != nil)
}

@Test @MainActor func invalidationCancelsActiveSaveNotOnlyQueuedTail() async throws {
    let transport = SlowDraftTransport()
    let queue = EditorDraftQueue(transport: transport)
    queue.save("draft.post.save", ["body": .string("old-account")])
    await transport.waitForStart()
    queue.save("draft.post.save", ["body": .string("queued-old-account")])
    queue.invalidate()
    try await Task.sleep(nanoseconds: 40_000_000)
    #expect(await transport.cancellations == 1)
    #expect(await transport.calls == 1)
}
actor SlowDraftTransport: NativeTransport {
    var calls = 0
    var cancellations = 0
    func waitForStart() async { while calls == 0 { await Task.yield() } }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls += 1
        do { try await Task.sleep(nanoseconds: 200_000_000) }
        catch { cancellations += 1; throw error }
        return .null
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}

@Test @MainActor func acceptedPostCannotBeSentTwiceWithoutNewEdits() async throws {
    let transport = RecordingTransport()
    let editor = EditorSession(mode: .post, transport: transport)
    editor.title = EditorBuffer(text: "标题"); editor.boardSlug = "tech"
    editor.changeBody(EditorBuffer(text: "正文"))
    _ = try await editor.submit()
    do { _ = try await editor.submit(); Issue.record("Duplicate publish") }
    catch { #expect((error as? NativeFailure)?.code == "ALREADY_ACCEPTED") }
    #expect(await transport.calls.count == 2)
}

@Test @MainActor func failedSendPreservesDraftAndNeverRetries() async throws {
    let transport = RecordingTransport(fail: true)
    let editor = EditorSession(mode: .message(uid: 4), transport: transport)
    editor.changeBody(EditorBuffer(text: "不能丢"))
    do { _ = try await editor.submit(); Issue.record("Expected failure") } catch { }
    #expect(editor.body.text == "不能丢")
    #expect(!editor.busy)
    #expect(await transport.calls.count == 1)
}

@Test @MainActor func postReplyEditUseDistinctPayloadsAndFlushBeforePublish() async throws {
    let transport = RecordingTransport()
    let post = EditorSession(mode: .post, transport: transport)
    post.title = EditorBuffer(text: "标题"); post.boardSlug = "tech"; post.permission = 255
    post.changeBody(EditorBuffer(text: "新帖"))
    _ = try await post.submit()
    let reply = EditorSession(mode: .reply(postID: 8), transport: transport)
    reply.replyContext = ["replyToFloor": .integer(3), "replyToAuthor": .string("作者")]
    reply.changeBody(EditorBuffer(text: "@作者 回复"))
    _ = try await reply.submit()
    let edit = EditorSession(mode: .edit(postID: 8, commentID: 9, page: 2, opening: false), transport: transport)
    edit.changeBody(EditorBuffer(text: "编辑回复"))
    _ = try await edit.submit()
    let calls = await transport.calls
    #expect(calls.map(\.0) == ["draft.post.save", "editor.post.publish", "draft.comment.save", "editor.comment.publish", "editor.edit.save"])
    #expect(calls[1].1["permission"] == .integer(255))
    #expect(calls[3].1["quotedFloor"] == .integer(3))
    #expect(calls[4].1["commentId"] == .integer(9))
    #expect(calls[4].1["isOpeningPost"] == .bool(false))
    #expect(calls[4].1["title"] == .string(""))
}

@Test @MainActor func invalidationSuppressesLateLoad() async throws {
    let transport = SuspendedTransport()
    let editor = EditorSession(mode: .edit(postID: 4, commentID: 5, page: 1, opening: true), transport: transport)
    let task = Task { try await editor.load() }
    await transport.waitForCall()
    editor.invalidate()
    await transport.finish(.object(["body": .string("旧账号私密正文")]))
    do { try await task.value; Issue.record("Old account load accepted") } catch is CancellationError { }
    #expect(editor.body.text.isEmpty)
    #expect(editor.pendingRestore == nil)
}

actor RecordingTransport: NativeTransport {
    var calls: [(String, [String: JSONValue])] = []
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((operation, arguments))
        if fail { throw NativeFailure(code: "NETWORK", message: "failed") }
        return .null
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
}

@Test func attachmentRejectsRemoteSourceAndIgnoresRemovedCompletion() throws {
    #expect(throws: NativeFailure.self) { try EditorAttachment(source: URL(string: "https://example.com/a.jpg")!, name: "a.jpg") }
    var item = try EditorAttachment(source: URL(fileURLWithPath: "/test/a.jpg"), name: "a.jpg")
    let token = item.begin()
    item.remove()
    item.complete(token, markdown: "![a](https://example.com/a.jpg)")
    #expect(item.phase == .removed)
    #expect(item.markdown == nil)
}

@Test func routesRejectIncompleteEditRatherThanPublishNewPost() throws {
    #expect(throws: NativeFailure.self) { try EditorMode.route("PostComposer", ["edit": .bool(true), "postId": .integer(7)]) }
    #expect(try EditorMode.route("PostComposer", ["reply": .bool(true), "postId": .integer(9007199254740993)]) == .reply(postID: 9007199254740993))
    #expect(EditorMarkup.receive(member: 7, reference: 100, amount: 2, description: "中 &+", onetime: true) == " nsapp://stardust-receive?member_id=7&ref_id=100&description=%E4%B8%AD%20%26%2B&diff=2&onetime=true ")
}

@Test @MainActor func restoringReplyPreservesQuoteContext() {
    let editor = EditorSession(mode: .reply(postID: 4), transport: SuspendedTransport())
    editor.restore(.object(["body": .string("回复"), "replyToFloor": .integer(9), "replyToAuthor": .string("作者"), "replyToText": .string("引用")]))
    #expect(editor.replyContext["replyToFloor"] == .integer(9))
    #expect(editor.replyContext["replyToAuthor"] == .string("作者"))
}

@Test @MainActor func handoffCommitsEveryMarkedFieldBeforeBlurAndAction() {
    var events: [String] = []
    let title = TestInput(name: "title", record: { events.append($0) })
    let body = TestInput(name: "body", record: { events.append($0) })
    EditorHandoff.perform([title, body]) { events.append("action") }
    #expect(events == ["title.commit", "body.commit", "title.snapshot", "body.snapshot", "title.blur", "body.blur", "action"])
}
@MainActor final class TestInput: EditorInput {
    let name: String
    let record: (String) -> Void
    init(name: String, record: @escaping (String) -> Void) { self.name = name; self.record = record }
    func commitMarkedText() { record(name + ".commit") }
    func snapshot() { record(name + ".snapshot") }
    func blur() { record(name + ".blur") }
}

@Test @MainActor func nullAcceptedMessageDoesNotInventBubbleOrEraseNewTyping() async throws {
    let transport = SuspendedTransport()
    let editor = EditorSession(mode: .message(uid: 9007199254740993), transport: transport)
    editor.changeBody(EditorBuffer(text: "发送正文"))
    let send = Task { try await editor.submit() }
    await transport.waitForCall()
    #expect(await transport.calls.first?.0 == "messages.send")
    #expect(await transport.calls.first?.1["uid"]?.int == 9007199254740993)
    do { _ = try await editor.submit(); Issue.record("overlapping send accepted") }
    catch { #expect((error as? NativeFailure)?.code == "IN_FLIGHT") }
    editor.changeBody(EditorBuffer(text: "下一条"))
    await transport.finish(.null)
    let result = try await send.value
    #expect(result == .null)
    #expect(editor.body.text == "下一条")
    #expect(!editor.accepted)
    #expect(await transport.calls.count == 1)
}

@Test @MainActor func draftSavesAreSerializedAndFlushWaitsForNewest() async throws {
    let transport = SuspendedTransport()
    let queue = EditorDraftQueue(transport: transport)
    queue.save("draft.post.save", ["body": .string("一")])
    await transport.waitForCall()
    queue.save("draft.post.save", ["body": .string("二")])
    await Task.yield()
    #expect(await transport.calls.count == 1)
    await transport.finish(.null)
    await transport.waitForCall(2)
    #expect(await transport.calls.last?.1["body"]?.string == "二")
    await transport.finish(.null)
    try await queue.flush()
}

@Test @MainActor func editorKeepsNewerTypingWhenLoadArrives() async throws {
    let transport = SuspendedTransport()
    let editor = EditorSession(mode: .edit(postID: 9007199254740993, commentID: 7, page: 2, opening: true), transport: transport)
    let load = Task { try await editor.load() }
    await transport.waitForCall()
    editor.changeBody(EditorBuffer(text: "新输入"))
    await transport.finish(.object(["body": .string("旧正文"), "title": .string("旧标题"), "permission": .integer(0)]))
    try await load.value
    #expect(editor.body.text == "新输入")
    #expect(editor.pendingRestore?["body"]?.string == "旧正文")
}

actor SuspendedTransport: NativeTransport {
    var calls: [(String, [String: JSONValue])] = []
    var continuation: CheckedContinuation<JSONValue, Error>?
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((operation, arguments))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> { AsyncThrowingStream { $0.finish() } }
    func waitForCall(_ count: Int = 1) async { while calls.count < count || continuation == nil { await Task.yield() } }
    func finish(_ value: JSONValue) { let c = continuation; continuation = nil; c?.resume(returning: value) }
}

@Test func utf16SelectionInsertionPreservesChineseAndEmoji() {
    var buffer = EditorBuffer(text: "中文😀末尾", selection: NSRange(location: 2, length: 2))
    buffer.wrap(prefix: "**", suffix: "**")
    #expect(buffer.text == "中文**😀**末尾")
    #expect(buffer.selection == NSRange(location: 4, length: 2))
}
