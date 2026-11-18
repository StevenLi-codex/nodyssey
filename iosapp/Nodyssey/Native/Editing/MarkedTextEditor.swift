import SwiftUI
import UIKit

/// UIKit owns the input session. SwiftUI never assigns text or selection while marked.
@MainActor final class NativeEditorTextView: UITextView, EditorInput {
    var onSnapshot: ((EditorBuffer) -> Void)?
    var onWindow: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); onWindow?() }
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
    private var initialFocus = EditorInitialFocus()
    private var initialFocusArmed = false
    func handoff(_ action: () -> Void) {
        if initialFocusArmed { initialFocus.cancel() }
        EditorHandoff.perform([title, body].compactMap { $0 }, action: action)
    }
    func requestInitialFocus() {
        initialFocusArmed = true
        guard let body else { return }
        func hasResponder(_ view: UIView) -> Bool {
            (view !== body && view.isFirstResponder) || view.subviews.contains(where: hasResponder)
        }
        let occupied = body.window.map(hasResponder) ?? false
        if initialFocus.consume(attached: body.window != nil, otherInputActive: occupied) {
            // Never commit or replace marked text merely to focus the initial body.
            if !body.isFirstResponder { body.becomeFirstResponder() }
        }
    }
    func refocus() { body?.becomeFirstResponder() }
    func cancelInitialFocus() { initialFocus.cancel() }
}

struct MarkedTextEditor: UIViewRepresentable {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String
    var autofocus = false
    // Opt-in for the inline reply only; the full editors keep their existing sizing.
    var maximumVisibleLines: Int? = nil

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeEditorTextView, context: Context) -> CGSize? {
        guard let maximumVisibleLines, let width = proposal.width, width > 0 else { return nil }
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let line = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = line * CGFloat(maximumVisibleLines) + insets
        return CGSize(width: width, height: min(max(line + insets, natural), limit))
    }

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
        if autofocus && !isTitle {
            view.onWindow = { [weak focus] in focus?.requestInitialFocus() }
            focus.requestInitialFocus()
        }
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
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focus.cancelInitialFocus() }
        func textViewDidChange(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidEndEditing(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
    }
}
