#if os(iOS)
import SwiftUI
import UIKit
import Combine

/// Each retained page uses an isolated, root-only NavigationStack for its SwiftUI
/// title/toolbar/search. It never owns the app route path, so there is no native
/// edge/content/historical pop that can bypass the departure decision. UIKit
/// containment below owns the two live surfaces and their visual commit/cancel.
struct NativeOwnedNavigation: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    let app: NativeAppModel
    let stack: NativeAppModel.Stack
    let rootID: UUID?
    let path: [NativeDestination]
    let isActive: Bool
    let root: AnyView

    func makeUIViewController(context: Context) -> NativeOwnedNavigationController {
        NativeOwnedNavigationController(app: app, stack: stack)
    }

    func updateUIViewController(_ owner: NativeOwnedNavigationController, context: Context) {
        owner.apply(rootID: rootID, path: path, active: isActive && scenePhase == .active,
                    rightToLeft: direction == .rightToLeft, reduceMotion: reduceMotion || motionDisabled) { [weak owner] id, destination in
            let screen = destination.map { AnyView(NativeScreen(destination: $0)) } ?? root
            let needsBack = destination.map { !["PostComposer", "MessageThread"].contains($0.route) } == true
            return AnyView(NavigationStack {
                screen.toolbar {
                    if needsBack {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button { owner?.requestBack(from: id) } label: {
                                Image(systemName: "chevron.backward")
                            }.accessibilityLabel(Text("action_back"))
                                .accessibilityIdentifier("BackButton")
                        }
                    }
                    if stack == .sheet, !["PostComposer", "MessageThread"].contains(destination?.route ?? "") {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("action_close") { Task { await app.dismissSheet() } }.disabled(app.departureRunning)
                        }
                    }
                }
            }
            .modifier(NativeOwnedPageEnvironment(inherited: environment))
            .environmentObject(app))
        }
    }

    static func dismantleUIViewController(_ owner: NativeOwnedNavigationController, coordinator: ()) { owner.detach() }
}

/// Preserve a page's own selection fence across the inherited environment copy.
private struct NativeOwnedPageEnvironment: ViewModifier {
    let inherited: EnvironmentValues
    func body(content: Content) -> some View {
        content.transformEnvironment(\.self) { values in
            let pageActive = values.nativeRichSelectionActive
            let pageLifetimes = values.nativeRichSelectionLifetimes
            values = inherited
            values.nativeRichSelectionActive = pageActive && inherited.nativeRichSelectionActive
            values.nativeRichSelectionLifetimes = inherited.nativeRichSelectionLifetimes + pageLifetimes
        }
    }
}

@MainActor final class NativeOwnedNavigationController: UIViewController, UIGestureRecognizerDelegate {
    private final class Page: UIHostingController<AnyView> {
        let id: UUID?
        let surface = UIView()
        let selection: NativeRichSelectionLifetime
        private var content: AnyView
        private var selectionActive = false
        init(id: UUID?, content: AnyView) {
            let lifetime = NativeRichSelectionLifetime()
            self.id = id; self.content = content; selection = lifetime
            super.init(rootView: AnyView(content.environment(\.nativeRichSelectionActive, false)
                .environment(\.nativeRichSelectionLifetimes, [lifetime])))
        }
        @MainActor required dynamic init?(coder: NSCoder) { nil }
        func updateContent(_ content: AnyView) { self.content = content; refreshContent() }
        func setSelectionActive(_ active: Bool) {
            guard selectionActive != active else { return }
            if !active { selection.revoke() }
            selectionActive = active
            refreshContent()
        }
        private func refreshContent() {
            rootView = AnyView(content.environment(\.nativeRichSelectionActive, selectionActive)
                .environment(\.nativeRichSelectionLifetimes, [selection]))
        }
    }

    private final class Motion {
        let lease: NativeAppModel.InteractivePop
        let from: Page
        let to: Page
        let width: CGFloat
        let rightToLeft: Bool
        let startX: Double
        var progress: CGFloat = 0
        var animator: UIViewPropertyAnimator?
        var prepare: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var cancelling = false
        init(lease: NativeAppModel.InteractivePop, from: Page, to: Page, width: CGFloat, rtl: Bool, startX: Double) {
            self.lease = lease; self.from = from; self.to = to; self.width = width; rightToLeft = rtl; self.startX = startX
        }
    }

    private let app: NativeAppModel
    private let stack: NativeAppModel.Stack
    private var pages: [Page] = []
    private var visible: Page?
    private var motion: Motion?
    private var projection: UIViewPropertyAnimator?
    private var active = false
    private var rtl = false
    private var reduceMotion = false
    private var identityRevoked = false
    private var subscriptions = Set<AnyCancellable>()
    private var start: CGPoint?
    private var ordinaryBack: Task<Void, Never>?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(track(_:)))

    init(app: NativeAppModel, stack: NativeAppModel.Stack) {
        self.app = app; self.stack = stack
        super.init(nibName: nil, bundle: nil)
        app.navigationIdentityWillRevoke.sink { [weak self] in self?.revokeIdentity() }.store(in: &subscriptions)
        app.objectWillChange.sink { [weak self] in
            // @Published fires before assignment; read the completed model mutation.
            Task { @MainActor [weak self] in
                guard let self, let motion = self.motion, !self.app.isInteractivePopCurrent(motion.lease) else { return }
                self.cancel(motion)
            }
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = UIView()
        view.clipsToBounds = true
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.isEnabled = false
        view.addGestureRecognizer(pan)
    }

    func apply(rootID: UUID?, path: [NativeDestination], active: Bool, rightToLeft: Bool, reduceMotion: Bool,
               content: @escaping (UUID?, NativeDestination?) -> AnyView) {
        loadViewIfNeeded()
        let motionBecameReduced = reduceMotion && !self.reduceMotion
        self.active = active; rtl = rightToLeft; self.reduceMotion = reduceMotion
        if !active { deactivateSelections() }
        if let motion {
            // A synchronous finish must replay this update, not an older policy
            // or the pre-pop path the representable brought in.
            deferredProjection = { [weak self] in
                guard let self, !self.identityRevoked else { return }
                self.apply(rootID: rootID, path: self.app.path(for: self.stack), active: active,
                           rightToLeft: rightToLeft, reduceMotion: reduceMotion, content: content)
            }
            if !active || rightToLeft != motion.rightToLeft || !app.isInteractivePopCurrent(motion.lease) {
                cancel(motion, immediate: reduceMotion)
            } else if motionBecameReduced, let animator = motion.animator, animator.state == .active {
                // Tracking and pending prepare have no animator. For settle,
                // keep the existing completion's commit/rollback validation.
                animator.stopAnimation(false)
                animator.finishAnimation(at: motion.cancelling ? .current : .end)
            }
            return
        }
        let ids = [rootID] + path.map { Optional($0.id) }
        if ids != pages.map(\.id) {
            let oldPages = pages
            pages = ids.enumerated().map { index, id in
                oldPages.first { $0.id == id } ?? Page(id: id, content: content(id, index == 0 ? nil : path[index - 1]))
            }
            let isPush = pages.count > oldPages.count && pages.dropLast(pages.count - oldPages.count).map(\.id) == oldPages.map(\.id)
            project(to: pages.last, forward: isPush, animated: active && !identityRevoked && !reduceMotion)
            for page in oldPages where page.surface.superview == nil { detach(page) }
        } else if motionBecameReduced, projection != nil {
            project(to: pages.last, forward: false, animated: false)
        }
        // Updating the rootView keeps the same hosting controller/SwiftUI identity.
        for (index, page) in pages.enumerated() {
            page.updateContent(content(page.id, index == 0 ? nil : path[index - 1]))
        }
        identityRevoked = false
        visible?.setSelectionActive(active)
        view.isHidden = false
        updatePan()
    }

    private func attach(_ page: Page) {
        page.setSelectionActive(active && !identityRevoked)
        let isNewChild = page.parent == nil
        if isNewChild {
            addChild(page)
            page.view.backgroundColor = .clear
            page.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            page.surface.backgroundColor = .systemBackground
            page.surface.addSubview(page.view)

        }
        if page.surface.superview !== view {
            page.surface.transform = .identity
            page.surface.frame = view.bounds
            page.view.frame = page.surface.bounds
            page.surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(page.surface)
        }
        if isNewChild { page.didMove(toParent: self) }
        // A retained hidden paragraph has synchronously discarded copy data.
        // Rebuild its live content before the first drag frame reveals it.
        page.view.setNeedsLayout()
        page.view.layoutIfNeeded()
    }

    private func detach(_ page: Page) {
        page.setSelectionActive(false)
        page.surface.removeFromSuperview()
        guard !pages.contains(where: { $0 === page }), page.parent === self else { return }
        page.willMove(toParent: nil)
        page.view.removeFromSuperview()
        page.removeFromParent()
    }

    private func showOnly(_ page: Page) {
        attach(page)
        page.surface.transform = .identity
        page.surface.isUserInteractionEnabled = true
        page.surface.accessibilityElementsHidden = false
        view.bringSubviewToFront(page.surface)
        visible = page
        for case let other as Page in children where other !== page { detach(other) }
    }

    private func project(to next: Page?, forward: Bool, animated: Bool) {
        projection?.stopAnimation(true)
        projection = nil
        guard let next else { return }
        guard let previous = visible, previous !== next, animated, view.window != nil, view.bounds.width > 0 else {
            showOnly(next); return
        }
        for case let other as Page in children where other !== previous && other !== next { detach(other) }
        attach(previous); attach(next)
        let span = view.bounds.width * (rtl ? -1 : 1)
        previous.surface.transform = .identity
        next.surface.transform = CGAffineTransform(translationX: forward ? span : -span * 0.24, y: 0)
        view.bringSubviewToFront(forward ? next.surface : previous.surface)
        previous.surface.isUserInteractionEnabled = false
        previous.surface.accessibilityElementsHidden = true
        next.surface.isUserInteractionEnabled = false
        visible = next
        let animator = UIViewPropertyAnimator(duration: 0.26, curve: .easeOut) {
            next.surface.transform = .identity
            previous.surface.transform = CGAffineTransform(translationX: forward ? -span * 0.24 : span, y: 0)
        }
        projection = animator
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self, self.projection === animator else { return }
            self.projection = nil
            self.showOnly(next)
            self.updatePan()
        }
        animator.startAnimation()
    }

    private func updatePan() {
        let enabled = active && pages.count > 1 && projection == nil && !identityRevoked
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
    }

    func requestBack(from id: UUID?) {
        guard active, motion == nil, projection == nil, ordinaryBack == nil, let id,
              app.path(for: stack).last?.id == id, visible?.id == id else { return }
        let owner = app.capturePathUpdateOwner()
        ordinaryBack = Task { [weak self] in
            guard let self else { return }
            defer { self.ordinaryBack = nil }
            guard !Task.isCancelled, self.active, self.visible?.id == id else { return }
            await app.updatePath(Array(app.path(for: stack).dropLast()), for: stack, owner: owner)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard active, pages.count > 1, let visible else { return super.accessibilityPerformEscape() }
        requestBack(from: visible.id)
        return true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        if let motion { cancel(motion, immediate: true) }
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewWillDisappear(_ animated: Bool) {
        if let motion { cancel(motion, immediate: true) }
        deactivateSelections()
        super.viewWillDisappear(animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible?.setSelectionActive(active && !identityRevoked)
    }

    private func deactivateSelections() {
        // Include a removed page still participating in an ordinary transition.
        for page in pages { page.setSelectionActive(false) }
        for case let page as Page in children { page.setSelectionActive(false) }
    }

    private func revokeIdentity() {
        guard isViewLoaded else { return }
        // A public authentication root keeps its WebKit owner through epoch
        // rotation. Never leave a pushed/private surface visible during revoke.
        let publicRoot = stack == .sheet && pages.count == 1 && app.ownsAuthenticationPresentation
        identityRevoked = true
        deactivateSelections()
        view.isHidden = !publicRoot
        deferredProjection = nil
        if let motion { cancel(motion, immediate: true) }
        projection?.stopAnimation(true); projection = nil
        ordinaryBack?.cancel()
        updatePan()
    }

    func detach() {
        active = false
        deactivateSelections()
        deferredProjection = nil
        if let motion { cancel(motion, immediate: true) }
        projection?.stopAnimation(true); projection = nil
        ordinaryBack?.cancel()
        subscriptions.removeAll()
    }

    private var canReceive: Bool {
        guard active, !identityRevoked, view.window != nil, let id = visible?.id,
              pages.count > 1, motion == nil, projection == nil, ordinaryBack == nil,
              app.canBeginInteractivePop(stack: stack, from: id) else { return false }
        var controller: UIViewController? = visible
        while let node = controller {
            if node.presentedViewController != nil { return false }
            controller = node.parent
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan, canReceive, let root = visible?.view, let hit = touch.view,
              hit === root || hit.isDescendant(of: root), !blocks(hit: hit, point: touch.location(in: root), root: root) else { return false }
        start = touch.location(in: view)
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, canReceive, pan.numberOfTouches == 1, let start, let root = visible?.view else { return false }
        let point = root.convert(start, from: view)
        guard let hit = root.hitTest(point, with: nil), !blocks(hit: hit, point: point, root: root) else { return false }
        let velocity = pan.velocity(in: view)
        return ContentBackSwipe.begins(velocityX: velocity.x, velocityY: velocity.y, rightToLeft: rtl)
    }

    private func blocks(hit: UIView, point: CGPoint, root: UIView) -> Bool {
        if NativeRichInteractionBoundary.hasActiveTextSelection(in: root) ||
            NativeRichInteractionBoundary.containsInteraction(at: point, in: root) || hasTextInteraction(in: root) { return true }
        // SwiftUI Slider may expose an adjustable accessibility element instead
        // of a UISlider. The Settings route owns the app's only such slider.
        if app.path(for: stack).last?.route == "Settings", hitsAdjustableElement(point, in: root) { return true }
        var cursor: UIView? = hit
        while let node = cursor {
            if node is UITextView || node is UITextField || node is UIControl || node.accessibilityTraits.contains(.adjustable) { return true }
            if let scroll = node as? UIScrollView, Self.ownsHorizontalDrag(scroll) { return true }
            if node === root { break }
            cursor = node.superview
        }
        return false
    }

    private func hitsAdjustableElement(_ point: CGPoint, in root: UIView) -> Bool {
        let screenPoint = UIAccessibility.convertToScreenCoordinates(CGRect(origin: point, size: .zero), in: root).origin
        func contains(_ node: UIView) -> Bool {
            guard !node.isHidden, node.alpha > 0.01, node.window === root.window,
                  !node.clipsToBounds || node.bounds.contains(node.convert(point, from: root)) else { return false }
            if let elements = node.accessibilityElements, elements.contains(where: { element in
                if let element = element as? UIAccessibilityElement {
                    return element.accessibilityTraits.contains(.adjustable) && element.accessibilityFrame.contains(screenPoint)
                }
                return false
            }) { return true }
            return node.subviews.contains(where: contains)
        }
        return contains(root)
    }

    private func hasTextInteraction(in node: UIView) -> Bool {
        guard !node.isHidden, node.alpha > 0.01 else { return false }
        if let text = node as? UITextView, text.isFirstResponder,
           text.markedTextRange != nil || text.selectedRange.length > 0 { return true }
        if let text = node as? UITextField, text.isFirstResponder, let range = text.selectedTextRange,
           text.markedTextRange != nil || !range.isEmpty { return true }
        return node.subviews.contains { hasTextInteraction(in: $0) }
    }

    private static func ownsHorizontalDrag(_ scroll: UIScrollView) -> Bool {
        scroll.isScrollEnabled && (scroll.isPagingEnabled || scroll.alwaysBounceHorizontal ||
            scroll.maximumZoomScale > scroll.minimumZoomScale ||
            scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right > scroll.bounds.width + 1)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let scroll = other.view as? UIScrollView else { return false }
        // Vertical scrolling waits for the directional decision to begin this
        // pan. Horizontal/zoom owners are never made to wait.
        return other === scroll.panGestureRecognizer && scroll.isDescendant(of: visible?.view ?? view) && !Self.ownsHorizontalDrag(scroll)
    }

    @objc private func track(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            guard let start, let from = visible, let id = from.id, let to = pages.dropLast().last,
                  view.bounds.width > 0, let lease = app.beginInteractivePop(stack: stack, from: id) else { return }
            guard to.id == lease.to else { app.cancelInteractivePop(lease); return }
            let motion = Motion(lease: lease, from: from, to: to, width: view.bounds.width, rtl: rtl, startX: start.x)
            self.motion = motion
            attach(to)
            to.surface.isUserInteractionEnabled = false
            to.surface.accessibilityElementsHidden = true
            view.bringSubviewToFront(from.surface)
            drag(motion, sender)
        case .changed:
            if let motion { drag(motion, sender) }
        case .ended:
            guard let motion, !motion.cancelling else { return }
            let distance = sender.translation(in: view)
            let projected = distance.x + sender.velocity(in: view).x * 0.18
            if ContentBackSwipe.shouldReturn(startX: motion.startX, width: motion.width,
                translationX: distance.x, translationY: distance.y, predictedX: projected, rightToLeft: motion.rightToLeft) {
                release(motion)
            } else { cancel(motion) }
        case .cancelled, .failed:
            if let motion { cancel(motion) }
        default: break
        }
    }

    private func drag(_ motion: Motion, _ recognizer: UIPanGestureRecognizer) {
        guard !motion.cancelling, view.bounds.width == motion.width, app.isInteractivePopCurrent(motion.lease) else { cancel(motion); return }
        motion.progress = ContentBackSwipe.progress(translationX: recognizer.translation(in: view).x,
                                                     width: motion.width, rightToLeft: motion.rightToLeft)
        render(motion, progress: motion.progress)
    }

    private func render(_ motion: Motion, progress: CGFloat) {
        let span = motion.width * (motion.rightToLeft ? -1 : 1)
        motion.from.surface.transform = CGAffineTransform(translationX: span * progress, y: 0)
        motion.to.surface.transform = CGAffineTransform(translationX: -span * (1 - progress) * 0.24, y: 0)
    }

    private func release(_ motion: Motion) {
        // Lock pointer interaction only after release. The old live editor
        // stays mounted; draft prepare may now perform its normal IME handoff.
        motion.from.surface.isUserInteractionEnabled = false
        motion.prepare = Task { [app, lease = motion.lease, weak self, weak motion] in
            guard self?.motion === motion, motion != nil else { return }
            let accepted = await app.prepareInteractivePop(lease)
            guard let self, let motion, self.motion === motion, !motion.cancelling else { return }
            motion.watchdog?.cancel()
            guard accepted, self.app.canFinishInteractivePop(motion.lease) else { self.cancel(motion); return }
            self.settle(motion, commit: true)
        }
        motion.watchdog = Task { [weak self, weak motion] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if let self, let motion, self.motion === motion { self.cancel(motion) }
        }
    }

    private func cancel(_ motion: Motion, immediate: Bool = false) {
        guard self.motion === motion, immediate || !motion.cancelling else { return }
        motion.cancelling = true
        motion.prepare?.cancel(); motion.watchdog?.cancel()
        if immediate {
            motion.animator?.stopAnimation(true)
            complete(motion, committed: false)
        } else if let animator = motion.animator, animator.state == .active {
            animator.isReversed = true
        } else { settle(motion, commit: false) }
    }

    private func settle(_ motion: Motion, commit: Bool) {
        guard !reduceMotion else {
            render(motion, progress: commit ? 1 : 0)
            complete(motion, committed: commit)
            return
        }
        let animator = UIViewPropertyAnimator(duration: 0.23, curve: .easeOut) { [weak self, weak motion] in
            if let motion { self?.render(motion, progress: commit ? 1 : 0) }
        }
        motion.animator = animator
        animator.addCompletion { [weak self, weak motion] position in
            guard let self, let motion, self.motion === motion else { return }
            let reachedTarget = position == .end && commit && !motion.cancelling
            if !reachedTarget && commit {
                motion.animator = nil
                self.settle(motion, commit: false)
            } else { self.complete(motion, committed: reachedTarget) }
        }
        animator.startAnimation()
    }

    private func complete(_ motion: Motion, committed: Bool) {
        guard self.motion === motion else { return }
        if committed, motion.to.surface.superview === view, pages.last === motion.from,
           pages.dropLast().last === motion.to, app.commitInteractivePop(motion.lease, visible: motion.to.id) {
            self.motion = nil
            pages.removeLast()
            showOnly(motion.to)
        } else if committed {
            motion.animator = nil
            cancel(motion)
            return
        } else {
            self.motion = nil
            app.cancelInteractivePop(motion.lease)
            showOnly(motion.from)
        }
        // A new path/tab/scene may have arrived during settle, even when there
        // is no @Published write at the end of a short swipe. Reapply the last
        // projection from the representable before enabling another gesture.
        updatePan()
        let reapply = deferredProjection
        deferredProjection = nil
        reapply?()
    }

    private var deferredProjection: (() -> Void)?
}
#endif
