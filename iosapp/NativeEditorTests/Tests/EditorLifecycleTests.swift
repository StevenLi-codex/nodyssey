import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

@Test @MainActor func failedChosenBufferSaveKeepsEditorAndOwnedFilesForRetry() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("fixture".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    model.addFile(url)
    let load = Task { await model.load() }
    await transport.waitForCall()
    model.session.changeBody(EditorBuffer(text: "B"))
    await transport.finish(.object(["body": .string("A")]))
    await load.value
    let close = Task { try await model.close(decision: .keepCurrent) }
    await transport.waitForCall(2)
    #expect(await transport.calls.last?.1["body"]?.string == "B")
    #expect(!model.isClosed)
    await transport.fail()
    do { try await close.value; Issue.record("Failed save dismissed editor") }
    catch { #expect((error as? NativeFailure)?.code == "NETWORK") }
    #expect(model.session.body.text == "B")
    #expect(!model.isClosed)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let retry = Task { try await model.close() }
    await transport.waitForCall(3)
    await transport.finish(.null)
    try await retry.value
    #expect(model.isClosed)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test @MainActor func failedDraftLoadBlocksCloseWithoutOverwritingStorage() async throws {
    let transport = RecordingTransport(fail: true)
    let model = EditorViewModel(mode: .reply(postID: 43), transport: transport, arguments: [:])
    model.session.changeBody(EditorBuffer(text: "保留B"))
    await model.load()
    do { try await model.close(); Issue.record("Failed load allowed close") }
    catch { #expect((error as? NativeFailure)?.code == "DRAFT_NOT_READY") }
    #expect(!model.isClosed)
    #expect(model.session.body.text == "保留B")
    #expect(await transport.calls.map(\.0) == ["draft.comment.get"])
}

@Test @MainActor func restoreChoiceSavesChosenStoredBufferBeforeDismissal() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
    let load = Task { await model.load() }
    await transport.waitForCall()
    model.session.changeBody(EditorBuffer(text: "B"))
    await transport.finish(.object(["body": .string("A"), "title": .string("标题A")]))
    await load.value
    let close = Task { try await model.close(decision: .restore) }
    await transport.waitForCall(2)
    #expect(!model.isClosed)
    #expect(await transport.calls.last?.1["body"]?.string == "A")
    #expect(await transport.calls.last?.1["title"]?.string == "标题A")
    await transport.finish(.null)
    try await close.value
    #expect(model.isClosed)
}

@Test @MainActor func discardCurrentLeavesUnresolvedStoredDraftUntouched() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .reply(postID: 42), transport: transport, arguments: [:])
    let load = Task { await model.load() }
    await transport.waitForCall()
    model.session.changeBody(EditorBuffer(text: "B"))
    await transport.finish(.object(["body": .string("A")]))
    await load.value
    try await model.close(decision: .discardCurrent)
    #expect(model.isClosed)
    #expect(await transport.calls.map(\.0) == ["draft.comment.get"])
}

@Test @MainActor func inputDuringCloseSaveKeepsEditorOpen() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .reply(postID: 41), transport: transport, arguments: [:])
    let load = Task { await model.load() }
    await transport.waitForCall()
    await transport.finish(.null)
    await load.value
    model.session.changeBody(EditorBuffer(text: "B"))
    let close = Task { try await model.close() }
    await transport.waitForCall(2)
    model.session.changeBody(EditorBuffer(text: "更新C"))
    await transport.finish(.null)
    do { try await close.value; Issue.record("Dismissed with unsaved C") }
    catch { #expect((error as? NativeFailure)?.code == "DRAFT_CHANGED") }
    #expect(!model.isClosed)
    #expect(model.session.body.text == "更新C")
    model.invalidate()
}

@Test @MainActor func closeCannotClaimFlushWhileDraftLoadIsIncomplete() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .post, transport: transport, arguments: [:])
    model.session.changeBody(EditorBuffer(text: "新输入B"))
    do { try await model.flush(); Issue.record("Close would discard B before loading A") }
    catch { #expect((error as? NativeFailure)?.code == "DRAFT_NOT_READY") }
    #expect(await transport.calls.isEmpty)
}

@Test @MainActor func unresolvedStoredDraftRequiresDecisionBeforeClose() async throws {
    let transport = SuspendedTransport()
    let model = EditorViewModel(mode: .reply(postID: 4), transport: transport, arguments: [:])
    let load = Task { await model.load() }
    await transport.waitForCall()
    model.session.changeBody(EditorBuffer(text: "新输入B"))
    await transport.finish(.object(["body": .string("存储A")]))
    await load.value
    do { try await model.flush(); Issue.record("Close would discard B with unresolved A") }
    catch { #expect((error as? NativeFailure)?.code == "DRAFT_DECISION_REQUIRED") }
    #expect(model.session.body.text == "新输入B")
    #expect(model.session.pendingRestore?["body"]?.string == "存储A")
    #expect(await transport.calls.count == 1)
    model.session.keepCurrent()
    let flush = Task { try await model.flush() }
    await transport.waitForCall(2)
    #expect(await transport.calls.last?.0 == "draft.comment.save")
    #expect(await transport.calls.last?.1["body"]?.string == "新输入B")
    await transport.finish(.null)
    try await flush.value
}
