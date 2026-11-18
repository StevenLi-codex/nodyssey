import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

@Test @MainActor func repeatedReplyStickerInsertionDoesNotBlurOrReplaceEditorSession() async throws {
    let model = EditorViewModel(mode: .reply(postID: 42), transport: RecordingTransport(), arguments: [:])
    let session = model.session
    var events: [String] = []
    let input = TestInput(name: "body", record: { events.append($0) })
    model.focus.inputs = [input]
    let original = "前😀替换后"
    session.changeBody(EditorBuffer(text: original, selection: (original as NSString).range(of: "替换")))
    model.insert(" :ac01: ", preservingInput: true)
    model.insert("😀", preservingInput: true)
    #expect(!events.contains("body.blur"))
    #expect(events == ["body.commit", "body.snapshot", "body.commit", "body.snapshot"])
    #expect(model.session === session)
    #expect(session.body.text == "前😀 :ac01: 😀后")
    #expect(session.body.selection == NSRange(location: (session.body.text as NSString).range(of: "后").location, length: 0))
    model.invalidate()
}

@Test @MainActor func replyModesToggleAndHideWithoutClosingDraftOwner() async throws {
    let owner = EditorReplyLifetime()
    await owner.open(postID: 42, transport: RecordingTransport(), generation: 1)
    let model = try #require(owner.model)
    let session = model.session
    session.changeBody(EditorBuffer(text: "draft😀", selection: NSRange(location: 5, length: 2)))
    model.setReplyInputMode(.emoji)
    #expect(model.replyInputMode == .emoji)
    model.toggleReplyInput()
    #expect(model.replyInputMode == .keyboard)
    model.toggleReplyInput()
    #expect(model.replyInputMode == .emoji)
    model.setReplyInputMode(.keyboard) // tap existing input
    #expect(model.replyInputMode == .keyboard)
    model.setReplyInputMode(.hidden) // cover/preview/photo/manage/close
    #expect(model.replyInputMode == .hidden)
    #expect(model.session === session)
    #expect(session.body == EditorBuffer(text: "draft😀", selection: NSRange(location: 5, length: 2)))
    model.setReplyInputMode(.emoji)
    #expect(await owner.hide())
    #expect(model.replyInputMode == .hidden)
    #expect(owner.model === model && !model.isClosed)
    owner.invalidate()
    #expect(model.replyInputMode == .hidden)
}

@Test @MainActor func coldObservedKeyboardDoesNotDiscardRequestedEmojiToggle() {
    let model = EditorViewModel(mode: .reply(postID: 42), transport: RecordingTransport(), arguments: [:])
    model.toggleReplyInput()
    model.focus.awaitingReplyEmojiMeasurement = true
    model.observedReplyInputMode(.keyboard) // Actual keyboard while measurement is pending.
    model.toggleReplyInput()
    #expect(model.replyInputMode == .keyboard)
    model.invalidate()
}

@Test @MainActor func actualKeyboardFallbackResetsEmojiTargetWhenNoMeasurementIsPending() {
    let model = EditorViewModel(mode: .reply(postID: 42), transport: RecordingTransport(), arguments: [:])
    model.setReplyInputMode(.emoji)
    model.observedReplyInputMode(.keyboard) // Rotation invalidated the docked measurement.
    model.toggleReplyInput()
    #expect(model.replyInputMode == .emoji)
    model.invalidate()
}
