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
            let threadBackDrag: (@MainActor (DragGesture.Value?, Bool) -> Void)?
            if destination?.route == "PostDetail" {
                threadBackDrag = { [weak owner] sample, ended in
                    owner?.trackThreadDrag(from: id, sample: sample, ended: ended)
                }
            } else {
                threadBackDrag = nil
            }
            return AnyView(NavigationStack {
                screen.environment(\.nativeThreadBackDrag, threadBackDrag).toolbar {
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
            let homeEndPageScope = values.homeEndPageScope
            let threadBackDrag = values.nativeThreadBackDrag
            values = inherited
            values.nativeThreadBackDrag = threadBackDrag
            values.homeEndPageScope = homeEndPageScope
            values.nativeRichSelectionActive = pageActive && inherited.nativeRichSelectionActive
            values.nativeRichSelectionLifetimes = inherited.nativeRichSelectionLifetimes + pageLifetimes
        }
    }
}

private struct NativeThreadBackDragKey: EnvironmentKey {
    static let defaultValue: (@MainActor (DragGesture.Value?, Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var nativeThreadBackDrag: (@MainActor (DragGesture.Value?, Bool) -> Void)? {
        get { self[NativeThreadBackDragKey.self] }
        set { self[NativeThreadBackDragKey.self] = newValue }
    }
}

private struct HomeEndPageScopeKey: EnvironmentKey {
    static let defaultValue: HomeEndRetentionMarker.Scope? = nil
}

extension EnvironmentValues {
    var homeEndPageScope: HomeEndRetentionMarker.Scope? {
        get { self[HomeEndPageScopeKey.self] }
        set { self[HomeEndPageScopeKey.self] = newValue }
    }
}

@MainActor final class NativeOwnedNavigationController: UIViewController, UIGestureRecognizerDelegate {
    private final class Page: UIHostingController<AnyView> {
        let id: UUID?
        let surface = UIView()
        let selection: NativeRichSelectionLifetime
        let homeEndScope: HomeEndRetentionMarker.Scope?
        private var content: AnyView
        private var selectionActive = false
        var homeDidLayout: (() -> Void)?
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            homeDidLayout?()
        }
        init(id: UUID?, content: AnyView, scopedHome: Bool) {
            let lifetime = NativeRichSelectionLifetime()
            let scope = scopedHome ? HomeEndRetentionMarker.Scope() : nil
            self.id = id; self.content = content; selection = lifetime; homeEndScope = scope
            super.init(rootView: AnyView(content.environment(\.nativeRichSelectionActive, false)
                .environment(\.nativeRichSelectionLifetimes, [lifetime]).environment(\.homeEndPageScope, scope)))
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
                .environment(\.nativeRichSelectionLifetimes, [selection]).environment(\.homeEndPageScope, homeEndScope))
        }
    }

    private final class Motion {
        let lease: NativeAppModel.InteractivePop
        let from: Page
        let to: Page
        let width: CGFloat
        let rightToLeft: Bool
        let returnsToHomeFromPost: Bool
        var translationCorrection = CGPoint.zero
        var releaseVelocity: CGFloat = 0
        var drivenByThread = false
        var startX: Double
        var dragOrigin: CGFloat = 0
        var progress: CGFloat = 0
        var animator: UIViewPropertyAnimator?
        var prepare: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var cancelling = false
        init(lease: NativeAppModel.InteractivePop, from: Page, to: Page, width: CGFloat, rtl: Bool, startX: Double, returnsToHomeFromPost: Bool) {
            self.lease = lease; self.from = from; self.to = to; self.width = width; rightToLeft = rtl; self.startX = startX
            self.returnsToHomeFromPost = returnsToHomeFromPost
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
    private let homeEnd = HomeEndRetention()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(track(_:)))

    init(app: NativeAppModel, stack: NativeAppModel.Stack) {
        self.app = app; self.stack = stack
        super.init(nibName: nil, bundle: nil)
        app.navigationIdentityWillRevoke.sink { [weak self] in self?.revokeIdentity() }.store(in: &subscriptions)
        if #available(iOS 26.0, *), stack == .home {
            // @Published supplies the new path synchronously before assignment.
            // Sample the still-visible root before SwiftUI projects tab hiding.
            app.$homePath.dropFirst().sink { [weak self] next in
                self?.homePathWillChange(to: next)
            }.store(in: &subscriptions)
            // Use the incoming values, not a deferred SwiftUI active update.
            // Away→back before projection cannot restore an already revoked lease.
            app.$selectedTab.dropFirst().sink { [weak self] next in
                if next != .home { self?.homeEnd.clear() }
            }.store(in: &subscriptions)
            app.$sheet.dropFirst().sink { [weak self] next in
                if next != nil { self?.homeEnd.clear() }
            }.store(in: &subscriptions)
            app.$generation.dropFirst().sink { [weak self] _ in self?.homeEnd.clear() }.store(in: &subscriptions)
            app.$settings.dropFirst().sink { [weak self] next in
                guard let self else { return }
                if next != self.app.settings { self.homeEnd.revokeReadPaint() }
                if next["einkMode"]?.bool == true || next["feedSort"] != self.app.settings["feedSort"] ||
                    next["onboardingSeen"] != self.app.settings["onboardingSeen"] {
                    self.homeEnd.clear()
                }
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification)
                .sink { [weak self] _ in self?.homeEnd.clear() }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)
                .sink { [weak self] notice in
                    guard let self, let scene = self.viewIfLoaded?.window?.windowScene,
                          (notice.object as? UIScene) === scene else { return }
                    self.homeEnd.clear()
                }.store(in: &subscriptions)
        }
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

    private var homeEndMotionAllowed: Bool {
        !reduceMotion && !UIAccessibility.isReduceMotionEnabled && app.settings["einkMode"]?.bool != true
    }

    private func scopedHomeOwner(_ page: Page) -> HomeEndRetention.Owner? {
        guard let host = page.viewIfLoaded, let scope = page.homeEndScope else { return nil }
        return scope.lookup(in: host).0
    }

    private func homePathWillChange(to next: [NativeDestination]) {
        let previous = app.homePath
        // An interactive drag already presents Home while the detail route is
        // still active. This experiment cannot correct that surface in time.
        guard motion == nil, homeEndMotionAllowed else { homeEnd.clear(); return }
        if previous.isEmpty, next.count == 1, let detail = next.first {
            homeEnd.clear()
            guard detail.route == "PostDetail", let post = detail.arguments["postId"]?.int,
                  active, app.selectedTab == .home, app.sheet == nil, !identityRevoked,
                  projection == nil, let home = pages.first, visible === home,
                  let window = viewIfLoaded?.window, home.surface.window === window,
                  let owner = scopedHomeOwner(home) else { return }
            homeEnd.departing(to: detail.id, post: post, owner: owner, window: window, app: app)
        } else {
            homeEnd.pathChanged(next: next.last?.id, count: next.count)
        }
    }

    private func restoreHomeEnd(_ page: Page) {
        guard homeEnd.pendingReturn else { return }
        guard homeEndMotionAllowed else { homeEnd.clear(); return }
        guard active, !identityRevoked, pages.first === page,
              app.homePath.isEmpty, app.selectedTab == .home, app.sheet == nil,
              let window = viewIfLoaded?.window, page.surface.window === window else { return }
        // attach() has mounted the surface but may still be inside UIKit's
        // first propagation pass. A truly missing owner on a mounted page
        // is terminal; a still-detached hosted view is not a sample.
        guard page.viewIfLoaded?.window === window, page.homeEndScope?.movingSurface != true else { return }
        guard let owner = scopedHomeOwner(page) else { homeEnd.clear(); return }
        _ = homeEnd.restore(owner: owner, window: window, generation: app.generation, currentOwner: {
            guard let host = page.viewIfLoaded else { return nil }
            return page.homeEndScope?.lookup(in: host).0
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if homeEnd.pendingReturn, let home = pages.first { restoreHomeEnd(home) }
    }

    func apply(rootID: UUID?, path: [NativeDestination], active: Bool, rightToLeft: Bool, reduceMotion: Bool,
               content: @escaping (UUID?, NativeDestination?) -> AnyView) {
        loadViewIfNeeded()
        let motionBecameReduced = reduceMotion && !self.reduceMotion
        self.active = active; rtl = rightToLeft; self.reduceMotion = reduceMotion
        if !active || reduceMotion { homeEnd.clear() }
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
                oldPages.first { $0.id == id } ?? Page(id: id, content: content(id, index == 0 ? nil : path[index - 1]),
                    scopedHome: stack == .home && index == 0)
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
        page.homeEndScope?.beginAttach()
        page.setSelectionActive(active && !identityRevoked)
        let isNewChild = page.parent == nil
        if isNewChild {
            addChild(page)
            page.homeEndScope?.bind(root: page.view, surface: page.surface)
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
            if homeEnd.pendingReturn, motion == nil, pages.first === page, !isNewChild, let scope = page.homeEndScope {
                scope.addReturningSurface(page.surface, to: view)
            } else {
                view.addSubview(page.surface)
            }
        }
        if isNewChild { page.didMove(toParent: self) }
        page.homeEndScope?.finishAttach()
        // A retained hidden paragraph has synchronously discarded copy data.
        // Rebuild its live content before the first drag frame reveals it.
        page.view.setNeedsLayout()
        if stack == .home, pages.first === page {
            page.homeDidLayout = { [weak self, weak page] in
                if let page { self?.restoreHomeEnd(page) }
            }
        }
        page.view.layoutIfNeeded()
        restoreHomeEnd(page)
    }

    private func detach(_ page: Page) {
        page.setSelectionActive(false)
        let retained = pages.contains(where: { $0 === page })
        if retained { page.homeEndScope?.park() }
        else { page.homeEndScope?.retire() }
        page.surface.removeFromSuperview()
        page.homeEndScope?.finishParking()
        guard !retained, page.parent === self else { return }
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
        // Do not leave a lease that can fire on a later, unrelated Home layout.
        if pages.count == 1, pages.first === page { homeEnd.clear() }
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
            await app.updatePath(Array(app.path(for: stack).dropLast()), for: stack, owner: owner,
                                 beforeOrdinaryHomeReturn: { [weak self] id in
                self?.homeEnd.authorizeBack(from: id)
            })
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard active, pages.count > 1, let visible else { return super.accessibilityPerformEscape() }
        requestBack(from: visible.id)
        return true
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        homeEnd.clear()
        if let motion { cancel(motion, immediate: true) }
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewWillDisappear(_ animated: Bool) {
        homeEnd.clear()
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
        homeEnd.clear()
        deactivateSelections()
        view.isHidden = !publicRoot
        deferredProjection = nil
        if let motion { cancel(motion, immediate: true) }
        projection?.stopAnimation(true); projection = nil
        ordinaryBack?.cancel()
        updatePan()
    }

    func detach() {
        homeEnd.clear()
        for page in pages { page.homeEndScope?.retire() }
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
              pages.count > 1, projection == nil, ordinaryBack == nil else { return false }
        if let motion {
            guard motion.from.id == id, motion.width == view.bounds.width, motion.animator?.state == .active,
                  app.canResumeInteractivePop(motion.lease) else { return false }
        } else if !app.canBeginInteractivePop(stack: stack, from: id) { return false }
        var controller: UIViewController? = visible
        while let node = controller {
            if node.presentedViewController != nil { return false }
            controller = node.parent
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: view)
        guard gestureRecognizer === pan, canReceive, admitsStart(at: point, actualHit: touch.view) else { return false }
        start = point
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, canReceive, pan.numberOfTouches == 1, let start,
              admitsStart(at: start) else { return false }
        let velocity = pan.velocity(in: view)
        if motion != nil { return abs(velocity.x) > abs(velocity.y) * 1.5 && velocity.x != 0 }
        // UIKit may zero translation at recognition. Measure from the accepted
        // touch-down so a slow horizontal drag still wins against vertical scrolling.
        let current = pan.location(in: view)
        return ContentBackSwipe.beginsAfterTouchDown(
            velocityX: velocity.x, velocityY: velocity.y,
            travelX: current.x - start.x, travelY: current.y - start.y, rightToLeft: rtl)
    }

    private func admitsStart(at start: CGPoint, actualHit: UIView? = nil) -> Bool {
        // During settle, both live pages are noninteractive. The parent pan
        // can catch the animation anywhere in its viewport, including the
        // revealed predecessor where the outgoing page no longer draws.
        if motion != nil { return view.bounds.contains(start) }
        guard let root = visible?.view else { return false }
        let point = root.convert(start, from: view)
        let hit = actualHit ?? root.hitTest(point, with: nil)
        guard let hit, hit === root || hit.isDescendant(of: root) else { return false }
        return !blocks(hit: hit, point: point, root: root)
    }

    private func blocks(hit: UIView, point: CGPoint, root: UIView) -> Bool {
        if NativeRichInteractionBoundary.hasActiveTextSelection(in: root) ||
            NativeRichInteractionBoundary.containsInteraction(at: point, in: root, includePlainText: false) ||
            hasTextInteraction(in: root) { return true }
        // SwiftUI Slider may expose an adjustable accessibility element instead
        // of a UISlider. The Settings route owns the app's only such slider.
        if app.path(for: stack).last?.route == "Settings", hitsAdjustableElement(point, in: root) { return true }
        var cursor: UIView? = hit
        while let node = cursor {
            if (node is UITextView && !(node is NativeSelectableTextView)) || node is UITextField ||
                node is UIControl || node.accessibilityTraits.contains(.adjustable) { return true }
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
            ContentBackSwipe.hasHorizontalContent(contentWidth: scroll.contentSize.width,
                boundsWidth: scroll.bounds.width, leftInset: scroll.adjustedContentInset.left,
                rightInset: scroll.adjustedContentInset.right))
    }

    private var isPostDetail: Bool { app.path(for: stack).last?.route == "PostDetail" }

    private func threadScrollOwning(_ recognizer: UIGestureRecognizer) -> UIScrollView? {
        guard isPostDetail, let root = visible?.view, let owner = recognizer.view,
              owner === root || owner.isDescendant(of: root) else { return nil }
        var candidate: UIView? = owner
        while let node = candidate {
            if let scroll = node as? UIScrollView, scroll.isScrollEnabled {
                return Self.ownsHorizontalDrag(scroll) ? nil : scroll
            }
            if node === root { break }
            candidate = node.superview
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let scroll = threadScrollOwning(other) else { return false }
        // A reader scroll can recognize before the outer UIKit pan. Keep both
        // alive until our own direction and rich-content checks admit Back.
        // Leave text selection, link taps and horizontal/zoom views independent.
        return other === scroll.panGestureRecognizer || other is UIPanGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let scroll = other.view as? UIScrollView else { return false }
        if threadScrollOwning(other) != nil { return false }
        // Other routes retain the directional failure relationship.
        return other === scroll.panGestureRecognizer && scroll.isDescendant(of: visible?.view ?? view) && !Self.ownsHorizontalDrag(scroll)
    }

    @objc private func track(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            if homeEnd.hasLease { homeEnd.clear() } // interactive is not this experiment
            if let motion, let start, resume(motion, at: start.x) {
                captureTranslationOrigin(motion, sender, start: start)
                drag(motion, sender)
                return
            }
            guard let start, let motion = beginMotion(at: start.x) else { return }
            captureTranslationOrigin(motion, sender, start: start)
            drag(motion, sender)
        case .changed:
            if let motion, !motion.drivenByThread { drag(motion, sender) }
        case .ended:
            guard let motion, !motion.drivenByThread, !motion.cancelling else { return }
            let distance = translation(motion, sender)
            let velocity = sender.velocity(in: view).x
            motion.releaseVelocity = motion.rightToLeft ? -velocity : velocity
            let travel = distance.x + motion.dragOrigin * motion.width * (motion.rightToLeft ? -1 : 1)
            let projected = travel + velocity * 0.18
            if ContentBackSwipe.shouldReturn(startX: motion.startX, width: motion.width,
                translationX: travel, translationY: distance.y, predictedX: projected, rightToLeft: motion.rightToLeft) {
                release(motion)
            } else { cancel(motion) }
        case .cancelled, .failed:
            if let motion, !motion.drivenByThread { cancel(motion) }
        default: break
        }
    }

    private func beginMotion(at startX: CGFloat) -> Motion? {
        guard let from = visible, let id = from.id, let to = pages.dropLast().last,
              view.bounds.width > 0, let lease = app.beginInteractivePop(stack: stack, from: id) else { return nil }
        guard to.id == lease.to else { app.cancelInteractivePop(lease); return nil }
        homeEnd.clear()
        let returningHome = stack == .home && to.id == nil && isPostDetail
        let motion = Motion(lease: lease, from: from, to: to, width: view.bounds.width, rtl: rtl,
                            startX: startX, returnsToHomeFromPost: returningHome)
        self.motion = motion
        attach(to)
        to.surface.isUserInteractionEnabled = false
        to.surface.accessibilityElementsHidden = true
        view.bringSubviewToFront(from.surface)
        return motion
    }

    func trackThreadDrag(from id: UUID?, sample: DragGesture.Value?, ended: Bool) {
        guard let id, visible?.id == id, isPostDetail else { return }
        guard let sample else {
            if let motion, motion.drivenByThread, motion.animator == nil, motion.prepare == nil { cancel(motion) }
            return
        }
        let distance = sample.translation
        if motion == nil, !ended, canReceive, let root = visible?.view,
           ContentBackSwipe.beginsAfterTouchDown(velocityX: 0, velocityY: 0,
               travelX: distance.width, travelY: distance.height, rightToLeft: rtl) {
            let start = view.convert(sample.startLocation, from: root)
            guard admitsStart(at: start), let created = beginMotion(at: start.x) else { return }
            created.drivenByThread = true
        }
        guard let motion, motion.drivenByThread, motion.animator == nil, !motion.cancelling,
              app.isInteractivePopCurrent(motion.lease) else { return }
        motion.progress = ContentBackSwipe.progress(translationX: distance.width, width: motion.width, rightToLeft: rtl)
        render(motion, progress: motion.progress)
        if ended {
            let projected = sample.predictedEndTranslation.width
            let velocity = (projected - distance.width) / 0.18
            motion.releaseVelocity = rtl ? -velocity : velocity
            if ContentBackSwipe.shouldReturn(startX: motion.startX, width: motion.width, translationX: distance.width,
                translationY: distance.height, predictedX: projected, rightToLeft: rtl) {
                release(motion)
            } else { cancel(motion) }
        }
    }

    private func captureTranslationOrigin(_ motion: Motion, _ recognizer: UIPanGestureRecognizer, start: CGPoint) {
        guard motion.returnsToHomeFromPost else { return }
        let location = recognizer.location(in: view)
        let reported = recognizer.translation(in: view)
        motion.translationCorrection = CGPoint(
            x: ContentBackSwipe.initialTranslationCorrection(start: start.x, current: location.x, reported: reported.x),
            y: ContentBackSwipe.initialTranslationCorrection(start: start.y, current: location.y, reported: reported.y)
        )
    }

    private func translation(_ motion: Motion, _ recognizer: UIPanGestureRecognizer) -> CGPoint {
        let reported = recognizer.translation(in: view)
        return CGPoint(x: reported.x + motion.translationCorrection.x, y: reported.y + motion.translationCorrection.y)
    }

    private func drag(_ motion: Motion, _ recognizer: UIPanGestureRecognizer) {
        guard !motion.cancelling, view.bounds.width == motion.width, app.isInteractivePopCurrent(motion.lease) else { cancel(motion); return }
        let travel = motion.dragOrigin * motion.width * (motion.rightToLeft ? -1 : 1) + translation(motion, recognizer).x
        motion.progress = ContentBackSwipe.progress(translationX: travel,
                                                     width: motion.width, rightToLeft: motion.rightToLeft)
        render(motion, progress: motion.progress)
    }

    @discardableResult private func resume(_ motion: Motion, at startX: Double) -> Bool {
        guard self.motion === motion, let animator = motion.animator, animator.state == .active,
              app.canResumeInteractivePop(motion.lease) else { return false }
        let translation = motion.from.surface.layer.presentation()?.affineTransform().tx
        let progress = translation.map { ContentBackSwipe.progress(translationX: $0,
            width: motion.width, rightToLeft: motion.rightToLeft) } ?? motion.progress
        motion.animator = nil
        animator.stopAnimation(true)
        motion.cancelling = false
        motion.startX = startX
        motion.progress = progress
        motion.dragOrigin = progress
        motion.releaseVelocity = 0
        render(motion, progress: progress)
        return true
    }

    private func render(_ motion: Motion, progress: CGFloat) {
        let span = motion.width * (motion.rightToLeft ? -1 : 1)
        motion.from.surface.transform = CGAffineTransform(translationX: span * progress, y: 0)
        let remaining = 1 - progress
        let parallax = motion.returnsToHomeFromPost ? 0.16 : 0.24
        motion.to.surface.transform = CGAffineTransform(translationX: -span * remaining * parallax, y: 0)
    }

    private func release(_ motion: Motion) {
        if app.canFinishInteractivePop(motion.lease) {
            settle(motion, commit: true)
            return
        }
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
        // The parent receives a second drag, but neither moving page should
        // execute a tap against UIKit's already-updated model frames.
        motion.from.surface.isUserInteractionEnabled = false
        motion.from.surface.accessibilityElementsHidden = true
        let duration = motion.returnsToHomeFromPost
            ? ContentBackSwipe.settleDuration(progress: motion.progress, width: motion.width,
                                              velocity: motion.releaseVelocity, completing: commit)
            : 0.23
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak self, weak motion] in
            if let motion { self?.render(motion, progress: commit ? 1 : 0) }
        }
        motion.animator = animator
        animator.addCompletion { [weak self, weak motion, weak animator] position in
            guard let self, let motion, let animator, self.motion === motion, motion.animator === animator else { return }
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

