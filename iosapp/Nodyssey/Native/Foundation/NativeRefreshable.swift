import SwiftUI

extension View {
    /// Keeps SwiftUI's async refresh action and the system scroll owner. `completion`
    /// can await a revision-backed store after its command merely acknowledges.
    @MainActor func nativeRefreshable(
        generation: Int = 0,
        failure: @escaping @MainActor () -> Bool = { false },
        completion: @escaping @MainActor () async -> Bool = { true },
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(NativeRefreshModifier(generation: generation, failure: failure, completion: completion, action: action))
    }
}

@MainActor private final class NativeRefreshPresentation: ObservableObject {
    @Published private(set) var state = NativeRefreshState()
    let coordinator = NativeRefreshCoordinator()
    init() {
        coordinator.onChange = { [weak self] in self?.state = $0 }
    }
}

private struct NativeRefreshModifier: ViewModifier {
    let generation: Int
    let failure: @MainActor () -> Bool
    let completion: @MainActor () async -> Bool
    let action: @MainActor () async -> Void
    @StateObject private var presentation = NativeRefreshPresentation()
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .refreshable {
                await presentation.coordinator.refresh(failure: failure, completion: completion, settle: {
                    // Post-success dwell only; never delay the request or failed response.
                    // The real UIRefreshControl stays open until this closure returns,
                    // then the platform performs its own natural inset collapse.
                    do { try await Task.sleep(nanoseconds: reduceMotion ? 180_000_000 : 340_000_000) }
                    catch { }
                }, action: action)
            }
            .background {
                #if os(iOS) && canImport(UIKit)
                NativeRefreshScrollBridge(presentation: presentation, environment: environment)
                    .allowsHitTesting(false).accessibilityHidden(true)
                #endif
            }
            .onAppear { presentation.coordinator.appear() }
            .onDisappear { presentation.coordinator.cancel() }
            .onChange(of: generation) { _ in
                presentation.coordinator.cancel()
                presentation.coordinator.appear()
            }
    }
}

/// All rendering lives in SwiftUI, including custom accent, contrast and motion
/// environments copied from the owning page into the refresh-control host.
private struct NativeRefreshRing: View {
    let state: NativeRefreshState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle().stroke(.tint, lineWidth: 2.5).opacity(0.18)
            if state.phase == .success {
                Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.tint)
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.8)))
            } else {
                Circle().trim(from: 0, to: state.phase == .refreshing ? 0.72 : state.progress)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90 + (rotating && !reduceMotion ? 360 : 0)))
                    .animation(state.phase == .refreshing && !reduceMotion
                        ? .linear(duration: 0.85).repeatForever(autoreverses: false) : nil,
                               value: rotating)
            }
        }
        .frame(width: 26, height: 26)
        .scaleEffect(reduceMotion || state.phase != .pulling ? 1 : 0.84 + 0.16 * state.progress)
        .opacity(state.phase == .pulling ? state.progress : (state.phase == .idle ? 0 : 1))
        // Drag samples track the finger directly. Only completed-state changes
        // get a light rebound; idle -> pulling must not spring the progress.
        .animation(reduceMotion || state.phase == .pulling ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: state.phase)
        .onChange(of: state.phase) { phase in rotating = phase == .refreshing }
        .onAppear { rotating = state.phase == .refreshing }
        .accessibilityHidden(true)
    }
}

#if os(iOS) && canImport(UIKit)
import UIKit

// SwiftUI refreshable(action:) exposes an async environment action, but no pull
// progress/custom-indicator slot (Apple documentation, refreshable(action:)).
// Keep its UIRefreshControl and all its original actions/insets. Only observe
// public UIScrollView properties and add a noninteractive SwiftUI drawing host.
// Remove this bridge if SwiftUI exposes native pull progress and indicator slots.
private struct NativeRefreshScrollBridge: UIViewRepresentable {
    let presentation: NativeRefreshPresentation
    let environment: EnvironmentValues

    func makeUIView(context: Context) -> NativeRefreshAnchor {
        let view = NativeRefreshAnchor()
        view.isUserInteractionEnabled = false
        view.configure(presentation: presentation, environment: environment)
        return view
    }
    func updateUIView(_ view: NativeRefreshAnchor, context: Context) {
        view.configure(presentation: presentation, environment: environment)
    }
    static func dismantleUIView(_ view: NativeRefreshAnchor, coordinator: ()) { view.detach() }
}

@MainActor private final class NativeRefreshAnchor: UIView {
    private weak var scroll: UIScrollView?
    private weak var control: UIRefreshControl?
    private weak var presentation: NativeRefreshPresentation?
    private var environment: EnvironmentValues?
    private var host: UIHostingController<AnyView>?
    private var savedTint: UIColor?
    private var savedTintWasNil = false
    private var observations: [NSKeyValueObservation] = []
    private var controlObservation: NSKeyValueObservation?
    private var baselineTop: CGFloat = 0
    private var resolving = false
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    private var lastPhase: NativeRefreshState.Phase = .idle

    func configure(presentation: NativeRefreshPresentation, environment: EnvironmentValues) {
        self.presentation = presentation; self.environment = environment
        if presentation.state.phase == .idle, lastPhase == .refreshing || lastPhase == .success {
            control?.endRefreshing()
        }
        lastPhase = presentation.state.phase
        // Keep the host's environment current even when the state is unchanged.
        render(presentation.state)
        resolve()
    }
    override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { resolve() }
    }
    override func layoutSubviews() { super.layoutSubviews(); resolve() }

    /// Never search UIApplication/windows or choose a global first scroll view.
    /// Prefer a real scroll ancestor. For modifiers outside ScrollViewReader or
    /// GeometryReader, accept only one scroll owner in the nearest local ancestor
    /// subtree, stopping at this view controller's root. Ambiguity fails closed.
    private func resolve() {
        guard !resolving, window != nil else { return }
        resolving = true
        defer { resolving = false }
        var root: UIView?
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { root = controller.view; break }
            responder = next
        }
        // Both searches are bounded by the same owning controller. A nested
        // controller must never decorate its parent's scroll view.
        guard let root else { if scroll != nil { detach() }; return }
        var ancestor = superview
        while let view = ancestor {
            if let owner = view as? UIScrollView, owner.refreshControl != nil { attach(owner); return }
            if view === root { break }
            ancestor = view.superview
        }
        ancestor = superview
        while let view = ancestor {
            let owners = scrollOwners(in: view)
            if owners.count == 1 { attach(owners[0]); return }
            // A subtree with several scroll owners is not an excuse to look wider.
            if owners.count > 1 || view === root { break }
            ancestor = view.superview
        }
        if scroll != nil { detach() }
    }

    private func scrollOwners(in view: UIView) -> [UIScrollView] {
        if view === self || view.isHidden { return [] }
        if let scroll = view as? UIScrollView, scroll.refreshControl != nil {
            // Only real refresh owners compete. Horizontal rails without a
            // refresh control must not make a sibling List ambiguous.
            return [scroll]
        }
        return view.subviews.flatMap { scrollOwners(in: $0) }
    }

    private func attach(_ owner: UIScrollView) {
        if scroll !== owner {
            detach()
            scroll = owner
            baselineTop = owner.adjustedContentInset.top
            owner.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
            observations = [
                owner.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.sample() }
                },
                owner.observe(\.refreshControl, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.attachControl() }
                }
            ]
        }
        attachControl()
    }

    private func attachControl() {
        guard let scroll, control !== scroll.refreshControl else { return }
        restoreControl()
        guard let refresh = scroll.refreshControl else { return }
        control = refresh
        savedTintWasNil = refresh.tintColor == nil
        savedTint = refresh.tintColor
        refresh.tintColor = .clear
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.view.backgroundColor = .clear
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let parent = next as? UIViewController {
                parent.addChild(host)
                break
            }
            responder = next
        }
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        refresh.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.centerXAnchor.constraint(equalTo: refresh.centerXAnchor),
            host.view.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
            host.view.widthAnchor.constraint(equalToConstant: 32),
            host.view.heightAnchor.constraint(equalToConstant: 32)
        ])
        host.didMove(toParent: host.parent)
        self.host = host
        controlObservation = refresh.observe(\.isRefreshing, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        render(presentation?.state ?? NativeRefreshState())
    }

    @objc private func panChanged() {
        guard let scroll else { return }
        if scroll.panGestureRecognizer.state == .began {
            if control?.isRefreshing != true { baselineTop = scroll.adjustedContentInset.top }
            feedback.prepare()
        }
        sample()
    }
    private func sample() {
        guard let scroll, let presentation, let control, control.bounds.height > 0 else { return }
        let dragging = scroll.panGestureRecognizer.state == .began || scroll.panGestureRecognizer.state == .changed
        // Normalize drawing and one-shot feedback to the measured control extent.
        // UIKit exposes no refresh-admission threshold: this is not a claim that
        // bounds.height equals its private trigger distance. Only the system
        // async action starts refreshing; a zero extent is not guessed here.
        let extent = control.bounds.height
        let distance = max(0, -scroll.contentOffset.y - baselineTop)
        if presentation.coordinator.pull(progress: Double(distance / extent), dragging: dragging) {
            feedback.impactOccurred(intensity: 0.65)
        }
        render(presentation.state)
    }
    private func render(_ state: NativeRefreshState) {
        guard let environment, let host else { return }
        host.rootView = AnyView(NativeRefreshRing(state: state).environment(\.self, environment))
    }
    private func restoreControl() {
        controlObservation?.invalidate(); controlObservation = nil
        host?.willMove(toParent: nil)
        host?.view.removeFromSuperview()
        host?.removeFromParent()
        host = nil
        if let control { control.tintColor = savedTintWasNil ? nil : savedTint }
        control = nil; savedTint = nil
    }
    func detach() {
        observations.forEach { $0.invalidate() }; observations.removeAll()
        scroll?.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
        // Dismantling can precede a cancellation-ignoring transport's drain. End
        // only our currently active presentation using the public lifecycle API;
        // never leave a hidden owner reserving the system refresh inset.
        if control != nil, lastPhase == .refreshing || lastPhase == .success ||
            presentation?.state.phase == .refreshing || presentation?.state.phase == .success {
            control?.endRefreshing()
            presentation?.coordinator.cancel()
        }
        restoreControl()
        scroll = nil
    }
}
#endif
