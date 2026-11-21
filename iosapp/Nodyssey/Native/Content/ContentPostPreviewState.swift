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
    let board: String
    let orderedBoards: [String]
    let isHomeRoot: Bool
    var site: String? = nil
    var sort: String? = nil
    var observation: UUID? = nil
}

/// A vertical scroll that bends sideways near lift-off must never switch boards.
/// This is only an observer; it doesn't cancel/delay List's native pan recognizer.
struct ContentFeedBoardSwipeTrace {
    private(set) var owner: ContentFeedBoardSwipeOwner?
    private var rejected = false

    mutating func record(_ owner: ContentFeedBoardSwipeOwner?, x: CGFloat, y: CGFloat) {
        guard self.owner == nil, !rejected else { return }
        self.owner = owner
        // A blocked first sample still belongs to this gesture. A later owner
        // or an unblocked menu must not turn the same touch into a new swipe.
        rejected = owner?.isHomeRoot != true || !x.isFinite || !y.isFinite ||
            abs(x) < abs(y) * ContentFeedBoardSwipe.horizontalDominance
    }

    mutating func finish(current: ContentFeedBoardSwipeOwner?, x: CGFloat, y: CGFloat, rightToLeft: Bool) -> String? {
        defer { cancel() }
        guard let owner, let current, !rejected else { return nil }
        return ContentFeedBoardSwipe.destination(start: owner, current: current,
            translationX: x, translationY: y, rightToLeft: rightToLeft)
    }

    // Revocation is not a recognizer reset: subsequent samples still belong to
    // the original touch. Only finish/cancel may admit a new gesture.
    mutating func revoke() { if owner != nil { rejected = true } }

    mutating func revoke(unless current: ContentFeedBoardSwipeOwner?) {
        if owner != current { revoke() }
    }

    mutating func cancel() { owner = nil; rejected = false }
}

enum ContentFeedBoardSwipe {
    static let minimumDistance: CGFloat = 72
    static let horizontalDominance: CGFloat = 1.5

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
        let next = (translationX < 0) != rightToLeft
        let destinationIndex = currentIndex + (next ? 1 : -1)
        guard current.orderedBoards.indices.contains(destinationIndex) else { return nil }
        let destination = current.orderedBoards[destinationIndex]
        return destination == current.board ? nil : destination
    }
}
