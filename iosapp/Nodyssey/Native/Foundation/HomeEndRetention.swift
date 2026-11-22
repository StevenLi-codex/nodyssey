#if os(iOS)
import UIKit
import Foundation
import NodysseyNativeCore

/// Ephemeral evidence owned by one armed ordinary Home return. ACK plus this
/// edge is local correlation, not proof of which Room write caused publication.
@MainActor final class HomeEndReadPaint {
    private enum Phase { case armed, marking(NativeAppModel.PathUpdateOwner), acknowledged, sealed, denied }
    private var phase = Phase.armed
    let route: UUID
    let post: Int64
    private let baseline: NativeStore.HomeFeedPresentation
    private weak var store: NativeStore?
    private var successor: NativeStore.HomeFeedPresentation?
    private(set) var wasSealed = false
    private var awaitingDispatch = false
    private var dispatched = false

    init(route: UUID, post: Int64, baseline: NativeStore.HomeFeedPresentation, store: NativeStore) {
        self.route = route; self.post = post; self.baseline = baseline; self.store = store
    }

    private func ownsDetail(in app: NativeAppModel) -> Bool {
        app.selectedTab == .home && app.sheet == nil && app.homePath.count == 1 &&
            app.homePath.first?.id == route && app.homePath.first?.route == "PostDetail" &&
            app.homePath.first?.arguments["postId"]?.int == post
    }

    func beginMark(route: UUID?, post: Int64?, in app: NativeAppModel) -> Bool {
        guard case .armed = phase, route == self.route, post == self.post, ownsDetail(in: app),
              app.paintObservedInFlight == 0,
              store?.homeFeedPresentation(in: app) == baseline else { revoke(); return false }
        phase = .marking(app.capturePathUpdateOwner())
        awaitingDispatch = true
        return true
    }

    /// Only the adapter's synchronous `requestStart` witness may open admission:
    /// a task that has merely been created can still be preceded by an already
    /// queued accepted publication.
    func dispatchBegan(_ operation: String) {
        guard case .marking = phase, awaitingDispatch, operation == "thread.markRead" else { return }
        awaitingDispatch = false
        dispatched = true
    }

    func finishMark(success: Bool, in app: NativeAppModel) {
        guard case .marking(let owner) = phase, dispatched, success, ownsDetail(in: app),
              app.capturePathUpdateOwner() == owner,
              store?.homeFeedPresentation(in: app) == (successor ?? baseline) else { revoke(); return }
        phase = .acknowledged
    }

    var isActive: Bool {
        if case .denied = phase { return false }
        return true
    }

    var needsComparator: Bool {
        guard successor == nil else { return false }
        switch phase {
        case .marking, .acknowledged: return true
        case .armed, .sealed, .denied: return false
        }
    }

    func accepted(_ receipt: NativeStore.HomeFeedPresentation, before: JSONValue?, value: JSONValue) {
        switch phase {
        case .marking, .acknowledged: break
        case .armed, .sealed, .denied: revoke(); return
        }
        guard dispatched, successor == nil, baseline.snapshot < UInt64.max, receipt.snapshot == baseline.snapshot + 1,
              receipt.store == baseline.store, receipt.observation == baseline.observation,
              receipt.pager == baseline.pager, receipt.refreshEpoch == baseline.refreshEpoch,
              let before, Self.exactDelta(before, value, post: post) else { revoke(); return }
        successor = receipt
    }

    func sealBack() {
        guard case .acknowledged = phase, successor != nil else { revoke(); return }
        phase = .sealed
        wasSealed = true
    }

    var sealedSuccessor: NativeStore.HomeFeedPresentation? {
        if case .sealed = phase { return successor }
        return nil
    }

    func revoke() { phase = .denied; successor = nil }

    // Scope to commands that can interfere with feed/Detail activity. Normal
    // position/draft saves and paging access hints still run unchanged.
    nonisolated static func conflicts(_ operation: String) -> Bool {
        HomeEndReadMarkPolicy.conflicts(operation)
    }

    static func exactDelta(_ before: JSONValue, _ after: JSONValue, post: Int64) -> Bool {
        guard let old = try? ContentPagingWindow(before), old.pagerID != nil,
              let new = try? ContentPagingWindow(after), new.pagerID == old.pagerID,
              (before["page"]?.int ?? 0) > 0, (before["totalPages"]?.int ?? 0) > 0,
              old.rows.allSatisfy({ ($0.page ?? 0) > 0 && $0.value["isRead"]?.bool != nil &&
                  ($0.value["newCommentCount"]?.int ?? -1) >= 0 }),
              ["refresh", "prepend", "append"].allSatisfy({
                  before[$0]?["status"]?.string == "NotLoading" && before[$0]?["endOfPaginationReached"]?.bool != nil
              }),
              let index = old.rows.firstIndex(where: { $0.id == post }),
              var object = before.object, var rows = before["items"]?.array, var row = rows[index].object,
              row["isRead"] == .bool(false), row["newCommentCount"] == .integer(0) else { return false }
        row["isRead"] = .bool(true)
        rows[index] = .object(row)
        object["items"] = .array(rows)
        return .object(object) == after
    }
}


/// This lease is for the retained Home List only. It is not a general saved scroll position.
@MainActor final class HomeEndRetention {
    struct FeedKey: Equatable {
        let generation: Int
        let ticket: UUID
        let intent: UUID
        let presentation: NativeStore.HomeFeedPresentation
    }

    struct Owner {
        let key: FeedKey
        let currentKey: @MainActor () -> FeedKey?
        let scroll: UIScrollView
        let control: UIRefreshControl
        let binding: UUID
        let render: UUID
        let renderEdge: RenderEdge?
        let store: NativeStore
    }

    struct RenderEdge {
        let previous: UUID
        let from: FeedKey
        let to: FeedKey
    }

    private struct Bounds: Equatable {
        let viewport: CGSize
        let content: CGSize
        let adjusted: UIEdgeInsets
        let raw: UIEdgeInsets
        let window: CGRect

        @MainActor init(_ scroll: UIScrollView, window: UIWindow) {
            viewport = scroll.bounds.size; content = scroll.contentSize
            adjusted = scroll.adjustedContentInset; raw = scroll.contentInset
            self.window = window.bounds
        }

        var maximum: CGFloat { max(-adjusted.top, content.height - viewport.height + adjusted.bottom) }
        var isFinite: Bool {
            [viewport.width, viewport.height, content.width, content.height,
             adjusted.top, adjusted.bottom, adjusted.left, adjusted.right,
             raw.top, raw.bottom, raw.left, raw.right].allSatisfy(\.isFinite)
        }
    }

    @MainActor private final class Lease {
        let routeID: UUID
        let key: FeedKey
        weak var scroll: UIScrollView?
        weak var control: UIRefreshControl?
        weak var window: UIWindow?
        let binding: UUID
        let render: UUID
        let paint: HomeEndReadPaint?
        let bounds: Bounds
        let offset: CGPoint
        let hiddenTabClamp: CGFloat
        var returning = false

        init(_ owner: Owner, window: UIWindow, bounds: Bounds, routeID: UUID, loss: CGFloat, paint: HomeEndReadPaint?) {
            self.routeID = routeID; key = owner.key; scroll = owner.scroll; control = owner.control; self.window = window
            binding = owner.binding; render = owner.render; self.paint = paint
            self.bounds = bounds; offset = owner.scroll.contentOffset; hiddenTabClamp = bounds.maximum - loss
        }
    }

    private var lease: Lease?
    var hasLease: Bool { lease != nil }
    var pendingReturn: Bool { lease?.returning == true }
    func clear() {
        lease?.paint?.revoke()
        lease = nil
    }

    func revokeReadPaint() { lease?.paint?.revoke() }

    private func idle(_ owner: Owner) -> Bool {
        let list = owner.scroll
        return list.refreshControl === owner.control && !owner.control.isRefreshing &&
            !list.isTracking && !list.isDragging && !list.isDecelerating && !list.isZooming
    }

    func departing(to routeID: UUID, post: Int64, owner: Owner, window: UIWindow, app: NativeAppModel) {
        clear()
        let list = owner.scroll
        let bounds = Bounds(list, window: window)
        let offset = list.contentOffset
        // UIKit's adjusted bottom includes the native tab occupancy when Home
        // is visible. Do not reserve it manually, change adjustment behavior,
        // or use a device constant. Measure the portion beyond the device inset.
        let loss = bounds.adjusted.bottom - bounds.raw.bottom - window.safeAreaInsets.bottom
        guard owner.key.generation == app.generation, owner.key == owner.currentKey(), list.window === window, idle(owner), bounds.isFinite,
              bounds.viewport.width > 0, bounds.viewport.height > 0, loss.isFinite, loss > 2,
              offset.x.isFinite, offset.y.isFinite, bounds.maximum - loss > -bounds.adjusted.top,
              abs(bounds.maximum - offset.y) <= 2 else { return }
        let paint = owner.store.armHomeEndReadPaint(in: app, route: routeID, post: post,
                                                  baseline: owner.key.presentation)
        lease = Lease(owner, window: window, bounds: bounds, routeID: routeID, loss: loss, paint: paint)
    }

    func authorizeBack(from routeID: UUID) {
        guard let lease, lease.routeID == routeID, !lease.returning else { return }
        lease.paint?.sealBack()
        lease.returning = true
    }

    func pathChanged(next: UUID?, count: Int) {
        guard let lease else { return }
        if count == 0, lease.returning { return } // explicitly authorized by the model
        if next != lease.routeID || count != 1 { clear() }
    }

    /// Call only from the existing synchronous attach/layout path while the
    /// returned Home root is being projected. Not a display-link correction.
    func restore(owner: Owner, window: UIWindow, generation: Int,
                 currentOwner: @MainActor () -> Owner?) -> Bool {
        guard let lease, lease.returning else { return false }
        let list = owner.scroll
        guard owner.key.generation == generation,
              list === lease.scroll, owner.control === lease.control, window === lease.window,
              window.bounds == lease.bounds.window, idle(owner) else { clear(); return false }
        guard owner.binding == lease.binding else { clear(); return false }
        let live = owner.currentKey()
        // No late repair after a stale, missing, or invalidated render.
        guard matchesReturnPresentation(owner, lease: lease, live: live) else {
            clear(); return false
        }
        guard list.window === window else { return false }
        let bounds = Bounds(list, window: window)
        // Host size and automatic insets can arrive in either order. Do not
        // write against a transient range or clamp into a different feed window.
        guard bounds == lease.bounds else { return false }
        let current = list.contentOffset
        guard current.x == lease.offset.x, abs(current.y - lease.hiddenTabClamp) <= 2,
              lease.offset.y - current.y > 2 else { return false }
        // Re-read both endpoints at the write boundary, not the saved marker.
        guard self.lease === lease else { return false }
        if lease.paint?.wasSealed == true {
            guard let latest = currentOwner(), latest.binding == lease.binding,
                  latest.scroll === list, latest.control === lease.control,
                  latest.key.generation == generation, list.window === window, idle(latest),
                  Bounds(list, window: window) == bounds, list.contentOffset == current,
                  matchesReturnPresentation(latest, lease: lease, live: latest.currentKey()),
                  self.lease === lease else {
                if self.lease === lease { clear() }
                return false
            }
        }
        clear() // consume before the write, including reentrant layout
        let target = min(bounds.maximum, max(-bounds.adjusted.top, lease.offset.y))
        UIView.performWithoutAnimation {
            list.setContentOffset(CGPoint(x: current.x, y: target), animated: false)
        }
        return true
    }

    private func matchesReturnPresentation(_ owner: Owner, lease: Lease, live: FeedKey?) -> Bool {
        guard owner.key == live else { return false }
        if owner.key == lease.key { return owner.render == lease.render }
        guard let successor = lease.paint?.sealedSuccessor, let edge = owner.renderEdge else { return false }
        return owner.key == lease.key.replacingPresentation(successor) && edge.previous == lease.render &&
            edge.from == lease.key && edge.to == owner.key
    }
}

private extension HomeEndRetention.FeedKey {
    func replacingPresentation(_ next: NativeStore.HomeFeedPresentation) -> Self {
        .init(generation: generation, ticket: ticket, intent: intent, presentation: next)
    }
}

/// Read the same List already resolved by the Home board-pan anchor. This
/// lookup never attaches, resolves, or alters a recognizer. Never pick a sibling
/// refresh scroll merely because it is the only one found during layout.
enum HomeEndRetentionMarker {
    struct Registration {
        let key: HomeEndRetention.FeedKey
        let currentKey: @MainActor () -> HomeEndRetention.FeedKey?
        let store: NativeStore
    }

    enum Lookup: String {
        case matched, wrongRoot, detached, empty, ambiguous, noRegistration, noBinding, invalidContainment, noRefreshControl
    }

    /// One weak roster per exact retained Home hosting Page, not a hierarchy search.
    @MainActor final class Scope {
        private final class Entry {
            weak var anchor: Anchor?
            init(_ anchor: Anchor) { self.anchor = anchor }
        }

        @MainActor private final class ParkedBinding {
            weak var anchor: Anchor?
            weak var root: UIView?
            weak var surface: UIView?
            weak var parent: UIView?
            weak var list: UIScrollView?
            weak var control: UIRefreshControl?
            weak var boundary: UIView?
            weak var window: UIWindow?
            let stamp: UUID
            var sawUnbinding = false
            var removed = false
            var claimed = false

            init(anchor: Anchor, root: UIView, surface: UIView, parent: UIView,
                 owner: HomeEndRetention.Owner, boundary: UIView, window: UIWindow) {
                self.anchor = anchor; self.root = root; self.surface = surface; self.parent = parent
                list = owner.scroll; control = owner.control; self.boundary = boundary; self.window = window
                stamp = owner.binding
            }
        }

        private enum Phase { case idle, insertingReturn }
        private var phase = Phase.idle
        private weak var root: UIView?
        private weak var surface: UIView?
        private var entries: [ObjectIdentifier: Entry] = [:]
        private var stamp = UUID() // Physical binding only; rendered history lives on the anchor.
        private var retired = false
        private var parked: ParkedBinding?
        private(set) var movingSurface = false

        func bind(root: UIView, surface: UIView) {
            guard !retired else { return }
            if let current = self.root, current !== root || self.surface !== surface { retire(); return }
            self.root = root; self.surface = surface
        }

        func insert(_ anchor: Anchor) {
            guard !retired else { return }
            let id = ObjectIdentifier(anchor)
            guard entries[id]?.anchor !== anchor else { return }
            entries = entries.filter { $0.value.anchor != nil }
            entries[id] = Entry(anchor)
            changed()
        }

        func remove(_ anchor: Anchor) {
            let id = ObjectIdentifier(anchor)
            guard entries[id]?.anchor === anchor else { return }
            entries.removeValue(forKey: id)
            changed()
        }

        func bindingChanged(_ anchor: Anchor) {
            guard entries[ObjectIdentifier(anchor)]?.anchor === anchor else { return }
            changed()
        }

        private func changed() { stamp = UUID() }

        func retire() {
            retired = true; root = nil; surface = nil; entries.removeAll()
            parked = nil; movingSurface = false
            changed()
        }

        func park() {
            // Only the owned Page's synchronous surface removal opens this interval.
            guard !retired, !movingSurface, parked == nil, let root, let window = root.window,
                  let surface, let parent = surface.superview, let owner = lookup(in: root).0,
                  let anchor = entries.values.first?.anchor, let boundary = anchor.rememberedBoundary else { return }
            parked = ParkedBinding(anchor: anchor, root: root, surface: surface, parent: parent,
                                   owner: owner, boundary: boundary, window: window)
            movingSurface = true
        }

        func finishParking() {
            if let parked, let surface, parked.surface === surface,
               surface.superview == nil, surface.window == nil { parked.removed = true }
            movingSurface = false
        }
        func beginAttach() { if parked != nil { movingSurface = true } }

        // Only the ordinary-return Page's actual synchronous addSubview owns this phase.
        // beginAttach (selection, sizing, containment, or another mount) is not enough.
        func addReturningSurface(_ surface: UIView, to parent: UIView) {
            guard phase == .idle, movingSurface, let parked, parked.removed, self.surface === surface,
                  parked.surface === surface, parked.parent === parent,
                  let window = parked.window, parent.window === window,
                  surface.superview == nil, surface.window == nil else { parent.addSubview(surface); return }
            phase = .insertingReturn
            defer { phase = .idle }
            parent.addSubview(surface)
        }

        func finishAttach() {
            if let parked {
                let completed = completedReturningBinding(parked)
                if !completed { changed() }
            }
            parked = nil; movingSurface = false
        }

        func claimReturningBinding(_ anchor: Anchor, list: UIScrollView, boundary: UIView, window: UIWindow) -> Bool {
            guard let parked else { return false }
            guard phase == .insertingReturn, movingSurface, parked.removed, parked.sawUnbinding, !parked.claimed,
                  ownsParkedBinding(parked, anchor: anchor, list: list, boundary: boundary, window: window) else { return false }
            parked.claimed = true
            return true
        }

        private func completedReturningBinding(_ parked: ParkedBinding) -> Bool {
            guard let anchor = parked.anchor, let list = parked.list, let boundary = parked.boundary,
                  let window = parked.window else { return false }
            guard phase == .idle, (!parked.sawUnbinding || parked.claimed), anchor.homeEndBoardBinding === list,
                  ownsParkedBinding(parked, anchor: anchor, list: list, boundary: boundary, window: window) else { return false }
            return true
        }

        private func ownsParkedBinding(_ parked: ParkedBinding, anchor: Anchor, list: UIScrollView,
                                       boundary: UIView, window: UIWindow) -> Bool {
            guard let root, let surface, let parent = parked.parent, let control = parked.control else { return false }
            let isSoleAnchor = entries.count == 1 && entries[ObjectIdentifier(anchor)]?.anchor === anchor
            guard self.parked === parked, stamp == parked.stamp, isSoleAnchor, anchor.homeEndRegistration != nil,
                  anchor === parked.anchor, list === parked.list, boundary === parked.boundary, window === parked.window,
                  anchor.rememberedScroll === list, anchor.rememberedBoundary === boundary, anchor.rememberedWindow === window,
                  list.refreshControl === control, root === parked.root, surface === parked.surface,
                  root.superview === surface, surface.superview === parent, parent.window === window,
                  root.window === window, surface.window === window, anchor.window === window,
                  list.window === window, boundary.window === window, control.window === window,
                  Self.visible(anchor, through: boundary, withinController: true),
                  Self.visible(list, through: boundary, withinController: true),
                  Self.visible(boundary, through: root) else { return false }
            return true
        }

        func noteParkedControl(_ anchor: Anchor, list: UIScrollView) {
            if let parked, parked.anchor === anchor, parked.list === list,
               list.refreshControl !== parked.control { bindingChanged(anchor) }
        }

        func permitsParkedUnbinding(_ anchor: Anchor, list: UIScrollView, boundary: UIView, window: UIWindow) -> Bool {
            guard phase == .idle, let parked, parked.window === window,
                  let root, let surface, root.superview === surface,
                  stamp == parked.stamp, anchor === parked.anchor, list === parked.list, boundary === parked.boundary,
                  root === parked.root, surface === parked.surface,
                  let control = parked.control, list.refreshControl === control,
                  anchor.isDescendant(of: boundary), list.isDescendant(of: boundary),
                  boundary === root || boundary.isDescendant(of: root) else { return false }
            // At least one endpoint must actually be losing its window. A
            // mounted resolve failure, reparent, or replacement is not parking.
            let windows = [root.window, anchor.window, list.window]
            let losingWindow = (surface.superview == nil || surface.window == nil) && windows.contains { $0 == nil } &&
                windows.allSatisfy { $0 == nil || $0 === window } &&
                Self.visible(anchor, through: boundary, withinController: true) &&
                Self.visible(list, through: boundary, withinController: true) &&
                Self.visible(boundary, through: root)
            if losingWindow { parked.sawUnbinding = true }
            return losingWindow
        }

        func lookup(in host: UIView) -> (HomeEndRetention.Owner?, Lookup) {
            guard !retired, root === host, let surface, host.superview === surface else { return (nil, .wrongRoot) }
            guard let window = host.window, surface.window === window, !movingSurface else { return (nil, .detached) }
            var live: [Anchor] = []
            var expired: [ObjectIdentifier] = []
            for (id, entry) in entries {
                if let anchor = entry.anchor { live.append(anchor) }
                else { expired.append(id) }
            }
            if !expired.isEmpty {
                for id in expired { entries.removeValue(forKey: id) }
                changed()
            }
            let matches = live
            guard matches.count == 1, let anchor = matches.first else {
                return (nil, matches.isEmpty ? .empty : .ambiguous)
            }
            guard let registration = anchor.homeEndRegistration else { return (nil, .noRegistration) }
            guard let list = anchor.homeEndBoardBinding, list === anchor.rememberedScroll,
                  let boundary = anchor.rememberedBoundary, anchor.rememberedWindow === window else { return (nil, .noBinding) }
            guard anchor.window === window, list.window === window, boundary.window === window,
                  Self.visible(anchor, through: boundary, withinController: true),
                  Self.visible(list, through: boundary, withinController: true),
                  Self.visible(boundary, through: host) else { return (nil, .invalidContainment) }
            guard let control = list.refreshControl else { return (nil, .noRefreshControl) }
            return (.init(key: registration.key, currentKey: registration.currentKey, scroll: list, control: control,
                          binding: stamp, render: anchor.renderStamp, renderEdge: anchor.renderEdge,
                          store: registration.store), .matched)
        }

        private static func visible(_ start: UIView, through root: UIView, withinController: Bool = false) -> Bool {
            // Verify only the known identity chain. The exact board-resolution
            // root can sit beneath the Page's SwiftUI navigation controller.
            guard start === root || start.isDescendant(of: root) else { return false }
            var view: UIView? = start
            while let node = view {
                if node.isHidden { return false }
                if node === root { return true }
                if withinController, node.next is UIViewController { return false }
                view = node.superview
            }
            return false
        }
    }

    @MainActor class Anchor: UIView {
        var homeEndRegistration: Registration? {
            didSet {
                let old = oldValue?.key, next = homeEndRegistration?.key
                guard old != next else { return }
                if let old, let next { renderEdge = .init(previous: renderStamp, from: old, to: next) }
                else { renderEdge = nil }
                renderStamp = UUID()
                if old != nil, next == nil { scope?.bindingChanged(self) }
            }
        }
        fileprivate private(set) var renderStamp = UUID()
        fileprivate private(set) var renderEdge: HomeEndRetention.RenderEdge?
        var homeEndScroll: UIScrollView? { nil }
        var homeEndBoardBinding: UIScrollView? { nil }
        private weak var scope: Scope?
        private var stopped = false
        private weak var anchorParent: UIView?
        fileprivate weak var rememberedScroll: UIScrollView?
        fileprivate weak var rememberedBoundary: UIView?
        fileprivate weak var rememberedWindow: UIWindow?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if anchorParent !== superview {
                scope?.bindingChanged(self)
                forgetHomeEndBinding()
            }
            anchorParent = superview
        }

        func connectHomeEnd(_ next: Scope?) {
            guard !stopped, scope !== next else { return }
            scope?.remove(self)
            forgetHomeEndBinding()
            scope = next
            next?.insert(self)
        }

        func retireHomeEnd() {
            connectHomeEnd(nil)
            stopped = true
        }

        func noteHomeEndBinding(_ list: UIScrollView, boundary: UIView, window: UIWindow) {
            guard let scope else { return }
            scope.noteParkedControl(self, list: list)
            if rememberedScroll !== list || rememberedBoundary !== boundary || rememberedWindow !== window {
                scope.bindingChanged(self)
                rememberedScroll = list; rememberedBoundary = boundary; rememberedWindow = window
            }
        }

        func claimHomeEndReturnBinding(_ list: UIScrollView, boundary: UIView, window: UIWindow) -> Bool {
            scope?.claimReturningBinding(self, list: list, boundary: boundary, window: window) == true
        }

        func noteHomeEndUnbinding() {
            guard let scope, let list = rememberedScroll, let boundary = rememberedBoundary, let window = rememberedWindow else {
                forgetHomeEndBinding(); return
            }
            if scope.permitsParkedUnbinding(self, list: list, boundary: boundary, window: window) { return }
            scope.bindingChanged(self)
            forgetHomeEndBinding()
        }

        private func forgetHomeEndBinding() { rememberedScroll = nil; rememberedBoundary = nil; rememberedWindow = nil }
    }
}
#endif
