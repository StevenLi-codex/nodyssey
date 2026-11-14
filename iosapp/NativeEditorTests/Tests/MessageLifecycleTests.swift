import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeEditor

// Serialize the tests sharing process-local draft memory; unique UIDs also keep
// these fixtures independent from state-only message tests.
@Suite(.serialized) @MainActor struct MessageLifecycleTests {
    @Test func acceptanceWhileAwayCannotResurrectSubmittedMessage() async throws {
        let transport = SuspendedTransport()
        let model = EditorViewModel(mode: .message(uid: 801), transport: transport, arguments: [:])
        await model.appear(generation: 1)
        model.session.changeBody(EditorBuffer(text: "发送A"))
        let send = Task { await model.submit() }
        await transport.waitForCall()
        model.cacheMessage() // tab disappears before acknowledgement
        await transport.finish(.null)
        await send.value
        await model.appear(generation: 1)
        #expect(model.session.body.text.isEmpty)
        #expect(model.session.accepted)
        #expect(MessageDraftMemory.values[801] == nil)
        #expect(await transport.calls.count == 1)
    }

    @Test func reappearanceDoesNotReplaceNewInputWithCachedSubmittedRevision() async throws {
        let transport = SuspendedTransport()
        let model = EditorViewModel(mode: .message(uid: 802), transport: transport, arguments: [:])
        await model.appear(generation: 1)
        model.session.changeBody(EditorBuffer(text: "发送A"))
        let send = Task { await model.submit() }
        await transport.waitForCall()
        model.cacheMessage()
        model.session.changeBody(EditorBuffer(text: "下一条B", selection: NSRange(location: 3, length: 0)))
        await model.appear(generation: 1)
        #expect(model.session.body.text == "下一条B")
        model.cacheMessage()
        await transport.finish(.null)
        await send.value
        #expect(MessageDraftMemory.values[802]?.buffer.text == "下一条B")
        let replacement = EditorViewModel(mode: .message(uid: 802), transport: transport, arguments: [:])
        await replacement.appear(generation: 1)
        #expect(replacement.session.body.text == "下一条B")
        #expect(replacement.session.body.selection == NSRange(location: 3, length: 0))
        #expect(MessageDraftMemory.values[802] == nil)
    }
}
