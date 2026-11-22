import Foundation
import NodysseyNativeCore

struct ContentPostPreviewOwner: Equatable {
    let id: UUID
    let postID: Int64
    let generation: Int
    let identityEpoch: String?
    let site: String?

    init(id: UUID = UUID(), postID: Int64, generation: Int, identityEpoch: String?, site: String?) {
        self.id = id
        self.postID = postID
        self.generation = generation
        self.identityEpoch = identityEpoch
        self.site = site
    }

    func matches(postID: Int64, generation: Int, identityEpoch: String?, site: String?) -> Bool {
        self.postID == postID && self.generation == generation &&
            self.identityEpoch == identityEpoch && self.site == site
    }
}

/// A context-menu preview owns only a short-lived local read. Late callbacks cannot
/// publish into a newer session, account, site, row, or menu presentation.
struct ContentPostPreviewLease {
    private(set) var current: ContentPostPreviewOwner?

    mutating func begin(_ owner: ContentPostPreviewOwner) { current = owner }

    func accepts(_ owner: ContentPostPreviewOwner, postID: Int64, generation: Int,
                 identityEpoch: String?, site: String?) -> Bool {
        current == owner && owner.matches(postID: postID, generation: generation,
                                           identityEpoch: identityEpoch, site: site)
    }

    mutating func cancel(_ owner: ContentPostPreviewOwner? = nil) {
        guard owner == nil || owner == current else { return }
        current = nil
    }
}

struct ContentPostPreviewContent: Equatable {
    let title: String
    let nodes: [JSONValue]
    let isBlocked: Bool

    init(postID: Int64, summary: JSONValue, thread: JSONValue) {
        let cached = thread.nativeInt("postId") == postID ? thread : .null
        let summary = summary["summary"] ?? summary
        let cachedTitle = cached.nativeString("title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        title = cachedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? summary.nativeString("title") ?? ""
        let body = cached["body"]
        isBlocked = body?.nativeBool("isBlocked") == true
        nodes = isBlocked ? [] : body?.nativeArray("nodes") ?? []
    }

    var hasBody: Bool { !isBlocked && !nodes.isEmpty }
}

struct ContentFeedBoardSwipeOwner: Equatable {
    let generation: Int
    let identityEpoch: String?
    var board: String
    let orderedBoards: [String]
    let isHomeRoot: Bool
    var site: String? = nil
    var sort: String? = nil
    var observation: UUID? = nil

    var scope: Self {
        var scope = self
        scope.observation = nil
        return scope
    }

    func selecting(_ board: String) -> Self {
        var scope = self.scope
        scope.board = board
        return scope
    }
}

struct ContentFeedBoardSwipeContext: Equatable {
    let scope: ContentFeedBoardSwipeOwner
    let current: ContentFeedBoardSwipeOwner?
}

struct ContentFeedBoardPresentation: Equatable {
    let offset: CGFloat
    let boardPosition: CGFloat
}

/// One admission per touch. The settle is presentation only: a successful end
/// returns the canonical selection immediately, before any frame is rendered.
struct ContentFeedBoardSwipeTrace {
    private struct Settle {
        let id = UUID()
        let scope: ContentFeedBoardSwipeOwner
        let sourceBoard: String
        let owner: ContentFeedBoardSwipeOwner?
        let start: TimeInterval
        let from: ContentFeedBoardPresentation
        let to: ContentFeedBoardPresentation
    }

    private struct Drag {
        let scope: ContentFeedBoardSwipeOwner
        // Only the exact observation present at begin can authorize a commit.
        let owner: ContentFeedBoardSwipeOwner?
        var visualOwner: ContentFeedBoardSwipeOwner?
        let base: ContentFeedBoardPresentation
        let origin: CGPoint
        let index: Int
        let rightToLeft: Bool
        let animated: Bool

        func displacement(x: CGFloat, y: CGFloat) -> CGPoint { .init(x: x - origin.x, y: y - origin.y) }

        func presentation(_ delta: CGPoint) -> ContentFeedBoardPresentation {
            let last = scope.orderedBoards.count - 1
            let minimum = CGFloat(max(0, index - 1))
            let maximum = CGFloat(min(last, index + 1))
            let direction: CGFloat = rightToLeft ? 1 : -1
            let travel = delta.x / 112
            let position = base.boardPosition + direction * travel

            // Clamp the resulting pose, not the direction. A caught settle may
            // start displaced even on an edge; reversal can always unwind it.
            // If a tap crosses several boards, include that sampled pose too.
            let bounds = min(minimum, base.boardPosition)...max(maximum, base.boardPosition)
            let canMoveLeft = rightToLeft ? index > 0 : index < last
            let canMoveRight = rightToLeft ? index < last : index > 0
            let left = min(base.offset, canMoveLeft ? -34 : 0)
            let right = max(base.offset, canMoveRight ? 34 : 0)
            return .init(offset: min(right, max(left, base.offset + 34 * travel)),
                         boardPosition: min(bounds.upperBound, max(bounds.lowerBound, position)))
        }
    }

    static let settleDuration: TimeInterval = 0.18
    private(set) var gestureID: UUID?
    private var drag: Drag?
    private var held: ContentFeedBoardPresentation?
    private var settle: Settle?
    var settleID: UUID? { settle?.id }
    func isSettling(on board: String) -> Bool { settle?.scope.board == board }

    mutating func begin(gesture: UUID, context: ContentFeedBoardSwipeContext, x: CGFloat, y: CGFloat,
                        rightToLeft: Bool, now: TimeInterval, animated: Bool = true) {
        guard gestureID == nil else { return }
        gestureID = gesture
        let scope = context.scope
        // Even a rejected first sample owns its sequence until a real terminal.
        guard scope.isHomeRoot, x.isFinite, y.isFinite, x != 0,
              abs(x) >= abs(y) * ContentFeedBoardSwipe.horizontalDominance,
              let index = scope.orderedBoards.firstIndex(of: scope.board) else { return }
        let current = context.current.flatMap { $0.scope == scope ? $0 : nil }
        let matchingSettle = settle?.scope == scope && (settle?.owner == nil || settle?.owner == current)
        let grabbed = animated && matchingSettle ? presentation(board: scope.board, now: now) : nil
        // A board handoff can catch its matching trajectory without borrowing
        // the outgoing pager or upgrading the drag when a new one arrives.
        guard current != nil || grabbed != nil else { return }
        settle = nil
        let drag = Drag(scope: scope, owner: current, visualOwner: current,
                        base: grabbed ?? .init(offset: 0, boardPosition: CGFloat(index)),
                        origin: grabbed == nil ? .init(x: 0, y: 0) : .init(x: x, y: y), index: index,
                        rightToLeft: rightToLeft, animated: animated)
        self.drag = drag
        if animated { held = drag.presentation(drag.displacement(x: x, y: y)) }
    }

    mutating func change(gesture: UUID, context: ContentFeedBoardSwipeContext, x: CGFloat, y: CGFloat) {
        guard gestureID == gesture, drag != nil else { return }
        synchronize(context)
        guard let drag else { return }
        guard x.isFinite, y.isFinite else { revokeGesture(); return }
        if drag.animated { held = drag.presentation(drag.displacement(x: x, y: y)) }
    }

    mutating func finish(gesture: UUID, context: ContentFeedBoardSwipeContext, x: CGFloat, y: CGFloat,
                         now: TimeInterval) -> String? {
        guard gestureID == gesture else { return nil }
        defer { resetGesture() }
        // A revoked touch can retire its sequence but cannot alter a newer tap's settle.
        guard drag != nil else { return nil }
        synchronize(context)
        guard let drag else { return nil }
        var target: String?
        if x.isFinite, y.isFinite {
            let delta = drag.displacement(x: x, y: y)
            if drag.animated { held = drag.presentation(delta) }
            if let owner = drag.owner, let current = context.current {
                target = ContentFeedBoardSwipe.destination(start: owner, current: current,
                    translationX: delta.x, translationY: delta.y, rightToLeft: drag.rightToLeft)
            }
        }
        if let held {
            startSettle(scope: drag.scope.selecting(target ?? drag.scope.board), from: held,
                        sourceBoard: drag.scope.board, owner: target == nil ? drag.visualOwner : nil, now: now)
        }
        return target
    }

    mutating func tap(scope: ContentFeedBoardSwipeOwner, target: String, now: TimeInterval, animated: Bool = true) {
        guard scope.board != target else { return }
        let matching = drag?.scope == scope || settle?.scope == scope
        let sampled = matching ? presentation(board: scope.board, now: now) : nil
        let from = sampled ?? scope.orderedBoards.firstIndex(of: scope.board)
            .map { ContentFeedBoardPresentation(offset: 0, boardPosition: CGFloat($0)) }
        revoke()
        if animated, scope.isHomeRoot, let from {
            startSettle(scope: scope.selecting(target), from: from, sourceBoard: scope.board, owner: nil, now: now)
        }
    }

    func presentation(board: String, now: TimeInterval) -> ContentFeedBoardPresentation? {
        if let held, drag?.scope.board == board { return held }
        guard let settle, settle.scope.board == board || settle.sourceBoard == board else { return nil }
        let elapsed = max(0, now - settle.start) / Self.settleDuration
        guard elapsed < 1 else { return nil }
        let remaining = CGFloat(1 - elapsed)
        let progress = 1 - remaining * remaining * remaining
        return .init(offset: settle.from.offset + (settle.to.offset - settle.from.offset) * progress,
                     boardPosition: settle.from.boardPosition + (settle.to.boardPosition - settle.from.boardPosition) * progress)
    }

    mutating func cancel(gesture: UUID, now: TimeInterval) {
        guard gestureID == gesture else { return }
        if let drag, let held {
            startSettle(scope: drag.scope, from: held, sourceBoard: drag.scope.board, owner: drag.visualOwner, now: now)
        }
        resetGesture()
    }

    mutating func complete(_ id: UUID) { if settleID == id { settle = nil } }

    func visualChanged(from previous: Self) -> Bool {
        held != previous.held || (held != nil && drag?.scope.board != previous.drag?.scope.board) ||
            settleID != previous.settleID
    }

    mutating func synchronize(_ context: ContentFeedBoardSwipeContext) {
        if let drag {
            if drag.scope != context.scope || (drag.visualOwner != nil && drag.visualOwner != context.current) {
                revokeGesture()
            } else if drag.visualOwner == nil, context.current?.scope == drag.scope {
                self.drag?.visualOwner = context.current
            }
        }
        if let settle, settle.scope != context.scope || (settle.owner != nil && settle.owner != context.current) {
            self.settle = nil
        }
    }

    mutating func revokeGesture() {
        // Later samples still belong to the old touch until finish/cancel.
        drag = nil
        held = nil
    }

    mutating func revoke() { revokeGesture(); settle = nil }
    mutating func cancel() { resetGesture(); settle = nil }

    private mutating func resetGesture() {
        gestureID = nil; revokeGesture()
    }

    private mutating func startSettle(scope: ContentFeedBoardSwipeOwner, from: ContentFeedBoardPresentation,
                                      sourceBoard: String, owner: ContentFeedBoardSwipeOwner?, now: TimeInterval) {
        guard let index = scope.orderedBoards.firstIndex(of: scope.board) else { return }
        let destination = ContentFeedBoardPresentation(offset: 0, boardPosition: CGFloat(index))
        guard from != destination else { return }
        settle = .init(scope: scope, sourceBoard: sourceBoard, owner: owner, start: now, from: from, to: destination)
    }
}

enum ContentFeedBoardSwipe {
    static let minimumDistance: CGFloat = 72
    static let horizontalDominance: CGFloat = 1.5

    static func movesForward(translationX: CGFloat, rightToLeft: Bool) -> Bool {
        (translationX < 0) != rightToLeft
    }

    static func destination(start: ContentFeedBoardSwipeOwner, current: ContentFeedBoardSwipeOwner,
                            translationX: CGFloat, translationY: CGFloat, rightToLeft: Bool) -> String? {
        guard start == current, start.isHomeRoot,
              translationX.isFinite, translationY.isFinite,
              abs(translationX) >= minimumDistance,
              abs(translationX) >= abs(translationY) * horizontalDominance,
              let currentIndex = current.orderedBoards.firstIndex(of: current.board),
              Set(current.orderedBoards).count == current.orderedBoards.count else { return nil }

        // A leftward gesture reveals the next board in LTR; the visual direction
        // reverses in RTL, matching a native horizontally paged control.
        let next = movesForward(translationX: translationX, rightToLeft: rightToLeft)
        let destinationIndex = currentIndex + (next ? 1 : -1)
        guard current.orderedBoards.indices.contains(destinationIndex) else { return nil }
        let destination = current.orderedBoards[destinationIndex]
        return destination == current.board ? nil : destination
    }
}
