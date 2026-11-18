import SwiftUI
import UIKit

/// UIKit owns the input session. SwiftUI never assigns text or selection while marked.
@MainActor final class NativeEditorTextView: UITextView, EditorInput {
    var onSnapshot: ((EditorBuffer) -> Void)?
    var onWindow: (() -> Void)?
    var onReplyInputMode: ((EditorReplyInputMode) -> Void)?
    private(set) var replyInputMode: EditorReplyInputMode = .hidden
    private var replyPanel: NativeReplyInputView?
    private var replyController: NativeReplyInputController?
    override var inputViewController: UIInputViewController? {
        replyInputMode == .emoji ? replyController : super.inputViewController
    }
    private(set) var awaitingEmojiMeasurement = false
    private var inputRequest = UUID()
    private var systemMeasurement: (window: ObjectIdentifier, size: CGSize, height: CGFloat)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { systemMeasurement = nil }
        onWindow?()
    }
    func configureReplyInput(_ content: AnyView?) {
        guard let content else { return }
        if let replyPanel { replyPanel.host.rootView = content }
        else {
            let panel = NativeReplyInputView(content: content)
            replyPanel = panel
            replyController = NativeReplyInputController(panel: panel)
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        }
    }
    private var measuredHeight: CGFloat? {
        guard let window, let measurement = systemMeasurement,
              measurement.window == ObjectIdentifier(window), measurement.size == window.bounds.size else { return nil }
        return measurement.height
    }
    @objc private func keyboardFrameChanged(_ note: Notification) {
        // Never learn our own custom input's size as a system-keyboard measurement.
        guard replyPanel != nil, isFirstResponder, replyInputMode == .keyboard,
              inputView == nil, let window,
              let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let local = window.convert(frame, from: window.screen.coordinateSpace)
        let overlap = window.bounds.intersection(local)
        // Floating/split/external keyboards are not a docked replacement height.
        guard !overlap.isNull, abs(local.maxY - window.bounds.maxY) < 1,
              local.minX <= window.bounds.minX + 1, local.maxX >= window.bounds.maxX - 1,
              overlap.height > window.safeAreaInsets.bottom else { systemMeasurement = nil; return }
        systemMeasurement = (ObjectIdentifier(window), window.bounds.size, overlap.height)
        if awaitingEmojiMeasurement { setNeedsLayout() }
    }
    private func captureSystemLayoutGuide() {
        guard inputView == nil, isFirstResponder, let window else { return }
        let local = window.keyboardLayoutGuide.layoutFrame
        let overlap = window.bounds.intersection(local)
        guard !overlap.isNull, abs(local.maxY - window.bounds.maxY) < 1,
              local.width >= window.bounds.width - 1, overlap.height > window.safeAreaInsets.bottom else { return }
        systemMeasurement = (ObjectIdentifier(window), window.bounds.size, overlap.height)
    }
    func setReplyInputMode(_ mode: EditorReplyInputMode) {
        guard replyPanel != nil || mode == .hidden else { return }
        inputRequest = UUID()
        if mode == .emoji && !awaitingEmojiMeasurement { captureSystemLayoutGuide() }
        if mode == .emoji && measuredHeight == nil {
            // A zero-frame UIInputView is not a usable fallback on all OS versions.
            // Keep the real keyboard until UIKit supplies its actual docked geometry.
            EditorHandoff.perform([self], preservingInput: true) {}
            awaitingEmojiMeasurement = true
            if !isFirstResponder { becomeFirstResponder() }
            replyInputMode = .keyboard
            onReplyInputMode?(.keyboard)
            return
        }
        awaitingEmojiMeasurement = false
        EditorHandoff.perform([self], preservingInput: mode != .hidden) {
            replyInputMode = mode
            if mode == .emoji {
                replyPanel?.setMeasuredSize(width: window?.bounds.width, height: measuredHeight)
                inputView = replyPanel
            } else { inputView = nil }
            // Public API replaces immediately (it does not promise animation).
            if isFirstResponder { reloadInputViews() }
            if mode != .hidden && !isFirstResponder { becomeFirstResponder() }
            onReplyInputMode?(mode)
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Rotation/window resizing must not keep a portrait keyboard constraint.
        if awaitingEmojiMeasurement {
            if measuredHeight != nil {
                // Defer out of layout; the target responder/window is checked again.
                let request = inputRequest
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.inputRequest == request, self.isFirstResponder, self.replyInputMode == .keyboard else { return }
                    self.setReplyInputMode(.emoji)
                }
            }
        }
        if replyInputMode == .emoji, measuredHeight == nil {
            // A changed window size invalidates the old docked geometry. Ask the
            // system keyboard again rather than keeping a stale portrait height.
            setReplyInputMode(.keyboard)
            // Leave the system keyboard active after a size change. Automatically
            // reopening here can mistake an outgoing-frame notification for the
            // new docked height. The next explicit emoji tap samples the guide.
        }
    }
    func replyDidBeginEditing() {
        guard replyPanel != nil else { return }
        if replyInputMode != .emoji { replyInputMode = .keyboard }
        onReplyInputMode?(replyInputMode)
    }
    func replyDidEndEditing() {
        guard replyPanel != nil else { return }
        awaitingEmojiMeasurement = false; inputRequest = UUID()
        replyInputMode = .hidden; inputView = nil
        onReplyInputMode?(.hidden)
    }
    func dismantleReplyInput() {
        if replyPanel != nil { setReplyInputMode(.hidden) }
        replyPanel?.detach(); replyPanel = nil; replyController = nil
        NotificationCenter.default.removeObserver(self)
        onReplyInputMode = nil; onSnapshot = nil; onWindow = nil
    }
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

/// The responder supplies this public controller together with inputView, so
/// UIKit owns its presentation and the hosting child has an unambiguous parent.
@MainActor private final class NativeReplyInputController: UIInputViewController {
    private let panel: NativeReplyInputView
    init(panel: NativeReplyInputView) { self.panel = panel; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        inputView = panel
        addChild(panel.host)
        panel.host.didMove(toParent: self)
    }
}

/// Public inputView host. UIKit alone owns avoidance; this view never adds insets.
@MainActor private final class NativeReplyInputView: UIInputView {
    let host: UIHostingController<AnyView>
    private var measuredHeight: CGFloat?
    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        super.init(frame: .zero, inputViewStyle: .keyboard)
        // Without a real measurement UIKit chooses its standard input-view size.
        allowsSelfSizing = false
        autoresizingMask = [.flexibleWidth]
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setMeasuredSize(width: CGFloat?, height: CGFloat?) {
        // UIKit takes the initial inputView frame as its encapsulated width;
        // a zero-width frame remains zero even with edge-pinned hosted content.
        if let width, width > 0 { frame.size.width = width }
        guard measuredHeight != height else { return }
        measuredHeight = height; allowsSelfSizing = height != nil
        if let height { frame.size.height = height }
        invalidateIntrinsicContentSize(); setNeedsLayout()
    }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight ?? UIView.noIntrinsicMetric)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
                                         verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        guard let measuredHeight else { return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal, verticalFittingPriority: vertical) }
        return CGSize(width: targetSize.width, height: measuredHeight)
    }
    func detach() {
        guard host.parent != nil else { return }
        host.willMove(toParent: nil); host.removeFromParent()
    }
}

@MainActor final class EditorFocus: ObservableObject {
    weak var title: NativeEditorTextView?
    weak var body: NativeEditorTextView?
    private var initialFocus = EditorInitialFocus()
    private var initialFocusArmed = false
    func handoff(preservingInput: Bool = false, _ action: () -> Void) {
        if initialFocusArmed { initialFocus.cancel() }
        EditorHandoff.perform([title, body].compactMap { $0 }, preservingInput: preservingInput, action: action)
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
    func applyReplyInputMode(_ mode: EditorReplyInputMode) { body?.setReplyInputMode(mode) }
    func applyBody(_ buffer: EditorBuffer) { body?.apply(buffer) }
    var awaitingReplyEmojiMeasurement: Bool { body?.awaitingEmojiMeasurement ?? false }
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
    var replyInputContent: AnyView? = nil
    var onReplyInputMode: ((EditorReplyInputMode) -> Void)? = nil

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
        view.onReplyInputMode = onReplyInputMode
        view.configureReplyInput(replyInputContent)
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
    static func dismantleUIView(_ view: NativeEditorTextView, coordinator: Coordinator) { view.dismantleReplyInput() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkedTextEditor
        init(_ parent: MarkedTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focus.cancelInitialFocus(); (textView as? NativeEditorTextView)?.replyDidBeginEditing() }
        func textViewDidChange(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidChangeSelection(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot() }
        func textViewDidEndEditing(_ textView: UITextView) { (textView as? NativeEditorTextView)?.snapshot(); (textView as? NativeEditorTextView)?.replyDidEndEditing() }
    }
}
