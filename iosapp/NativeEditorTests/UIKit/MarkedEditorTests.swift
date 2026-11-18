#if canImport(UIKit)
import XCTest
import UIKit
import SwiftUI
import NodysseyNativeCore
@testable import Nodyssey

@MainActor final class MarkedEditorTests: XCTestCase {
    func testColdDoubleToggleCancelsEmojiAfterMeasurementArrives() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let model = EditorViewModel(mode: .reply(postID: 42), transport: UIKitInputTransport(), arguments: [:])
        let input = NativeEditorTextView(frame: controller.view.bounds)
        controller.view.addSubview(input)
        model.focus.body = input
        input.onReplyInputMode = { model.observedReplyInputMode($0) }
        input.configureReplyInput(AnyView(Text("Picker boundary")))
        model.toggleReplyInput()
        XCTAssertEqual(input.replyInputMode, .keyboard, "Cold request waits for docked geometry")
        model.toggleReplyInput()
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: CGRect(x: 0, y: 508, width: 390, height: 336)])
        input.setNeedsLayout(); input.layoutIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(input.replyInputMode, .keyboard)
        XCTAssertNil(input.inputView, "Late measurement must not reopen a cancelled request")
        input.dismantleReplyInput(); model.invalidate()
    }
    func testSameRunloopInsertPublishesToUIKitBeforeNextSnapshot() {
        let model = EditorViewModel(mode: .reply(postID: 42), transport: UIKitInputTransport(), arguments: [:])
        let input = NativeEditorTextView()
        model.focus.body = input
        input.text = "前😀替换后"
        input.selectedRange = (input.text as NSString).range(of: "替换")
        input.onSnapshot = { model.session.changeBody($0) }
        model.insert(" :ac01: ", preservingInput: true)
        model.insert("😀", preservingInput: true)
        XCTAssertEqual(model.session.body.text, "前😀 :ac01: 😀后")
        XCTAssertEqual(input.text, model.session.body.text)
        XCTAssertEqual(input.selectedRange, NSRange(location: 13, length: 0))
        model.invalidate()
    }
    func testChineseCompositionSurvivesPanelHandoff() {
        let input = NativeEditorTextView()
        input.text = "前"
        input.selectedRange = NSRange(location: 1, length: 0)
        input.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(input.markedTextRange)
        var captured = EditorBuffer()
        input.onSnapshot = { captured = $0 }
        EditorHandoff.perform([input]) {
            XCTAssertNil(input.markedTextRange)
            XCTAssertEqual(captured.text, "前中文")
            XCTAssertEqual(captured.selection, NSRange(location: 3, length: 0))
        }
    }
    func testReplySwitchAndRepeatedInsertRetainResponderAndUTF16Caret() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let input = NativeEditorTextView(frame: controller.view.bounds)
        controller.view.addSubview(input)
        input.becomeFirstResponder()
        input.text = "前😀替换后"
        input.selectedRange = (input.text as NSString).range(of: "替换")
        var captured = EditorBuffer()
        input.onSnapshot = { captured = $0 }
        input.configureReplyInput(AnyView(Text("Picker boundary")))
        input.setReplyInputMode(.emoji)
        XCTAssertTrue(input.isFirstResponder, "Switching to emoji must not blur")
        input.snapshot()
        XCTAssertEqual(captured.selection, NSRange(location: 3, length: 2))
        var buffer = captured
        buffer.insert(" :ac01: "); input.apply(buffer)
        buffer.insert("😀"); input.apply(buffer)
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertEqual(input.text, "前😀 :ac01: 😀后")
        XCTAssertEqual(input.selectedRange, NSRange(location: 13, length: 0))
        input.setReplyInputMode(.keyboard)
        XCTAssertNil(input.inputView)
        XCTAssertTrue(input.isFirstResponder)
        input.setReplyInputMode(.hidden)
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertEqual(input.text, buffer.text)
    }
    func testQueuedColdEmojiCannotReopenAfterExplicitHide() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let input = NativeEditorTextView(frame: controller.view.bounds)
        controller.view.addSubview(input)
        input.configureReplyInput(AnyView(Text("Picker boundary")))
        input.setReplyInputMode(.emoji)
        input.setReplyInputMode(.hidden)
        input.layoutIfNeeded()
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertNil(input.inputView)
        XCTAssertEqual(input.replyInputMode, .hidden)
        input.dismantleReplyInput()
    }
    func testSwiftUIUpdateDoesNotOverwriteMarkedText() {
        let input = NativeEditorTextView()
        input.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        input.apply(EditorBuffer(text: "older state"))
        XCTAssertEqual(input.text, "拼音")
        XCTAssertNotNil(input.markedTextRange)
    }
    func testInitialFocusPreservesCompositionAndDoesNotReturnAfterHandoff() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let input = NativeEditorTextView(frame: controller.view.bounds)
        controller.view.addSubview(input)
        let focus = EditorFocus()
        focus.body = input
        focus.requestInitialFocus()
        XCTAssertTrue(input.isFirstResponder)
        input.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        focus.requestInitialFocus()
        XCTAssertNotNil(input.markedTextRange)
        XCTAssertEqual(input.text, "拼音")
        focus.handoff {}
        focus.requestInitialFocus()
        XCTAssertFalse(input.isFirstResponder)
        XCTAssertEqual(input.text, "拼音")
    }
}
private struct UIKitInputTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue { .null }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
#endif
