import SwiftUI
import UIKit

/// UIKit owns the input session. SwiftUI never assigns text or selection while marked.
@MainActor final class NativeEditorTextView: UITextView, EditorInput {
    var onSnapshot: ((EditorBuffer) -> Void)?
    private var applying = false
    func apply(_ buffer: EditorBuffer) {
        guard markedTextRange == nil, !applying else { return }
        applying = true
        defer { applying = false }
        if text != buffer.text { text = buffer.text }
        if Range(buffer.selection, in: text ?? "") != nil, selectedRange != buffer.selection {
            selectedRange = buffer.selection
        }
    }
    func commitMarkedText() {
        guard markedTextRange != nil else { return }
        let selection = selectedRange
        unmarkText()
        if Range(selection, in: text ?? "") != nil { selectedRange = selection }
    }
    func snapshot() {
        guard !applying else { return }
        onSnapshot?(EditorBuffer(text: text ?? "", selection: selectedRange))
    }
    func blur() { resignFirstResponder() }
}

@MainActor final class EditorFocus: ObservableObject {
    weak var title: NativeEditorTextView?
    weak var body: NativeEditorTextView?
    func handoff(_ action: () -> Void) {
        EditorHandoff.perform([title, body].compactMap { $0 }, action: action)
    }
    func refocus() { body?.becomeFirstResponder() }
}

struct MarkedTextEditor: UIViewRepresentable {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String

    func makeUIView(context: Context) -> NativeEditorTextView {
        let view = NativeEditorTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: isTitle ? .headline : .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.accessibilityLabel = accessibilityLabel
        view.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        view.keyboardDismissMode = .interactive
        attach(view, context: context)
        view.apply(buffer)
        return view
    }
    func updateUIView(_ view: NativeEditorTextView, context: Context) {
        context.coordinator.parent = self
        attach(view, context: context)
        view.apply(buffer)
    }
    private func attach(_ view: NativeEditorTextView, context: Context) {
        if isTitle { focus.title = view } else { focus.body = view }
        let coordinator = context.coordinator
        view.onSnapshot = { [weak coordinator] value in
            guard let coordinator, coordinator.parent.buffer != value else { return }
            coordinator.parent.buffer = value
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkedTextEditor
        init(_ parent: MarkedTextEditor) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidEndEditing(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
    }
}
