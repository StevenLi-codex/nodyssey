#if canImport(UIKit)
import XCTest
import UIKit
@testable import Nodyssey

@MainActor final class MarkedEditorTests: XCTestCase {
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
    func testSwiftUIUpdateDoesNotOverwriteMarkedText() {
        let input = NativeEditorTextView()
        input.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0))
        input.apply(EditorBuffer(text: "older state"))
        XCTAssertEqual(input.text, "拼音")
        XCTAssertNotNil(input.markedTextRange)
    }
}
#endif
