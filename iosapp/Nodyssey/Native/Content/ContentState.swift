import Foundation
import CoreGraphics
import NodysseyNativeCore

/// The view owns task lifetime; the ticket prevents an old completion clearing a newer load.
struct ContentThreadPageLoad {
    private(set) var loading = false
    private var token = UUID()
    mutating func begin() -> UUID { token = UUID(); loading = true; return token }
    mutating func finish(_ ticket: UUID, cancelled: Bool) {
        // Cancellation suppresses publication, not cleanup of this task's loading lease.
        guard ticket == token else { return }
        loading = false
    }
    mutating func depart() { token = UUID(); loading = false }
}

/// Both direct comments and quoted replies use the existing editor route, never a send request.
enum ContentReplyAction: Equatable {
    case signIn
    case unavailable
    case compose([String: JSONValue])

    static func resolve(postID: Int64, signedIn: Bool, loaded: Bool, quote: JSONValue?) -> Self {
        guard signedIn else { return .signIn }
        guard loaded else { return .unavailable }
        var arguments: [String: JSONValue] = ["postId": .integer(postID), "reply": .bool(true)]
        if let floor = quote?["floor"]?.string.flatMap(ContentReadingTarget.floorNumber) { arguments["quotedFloor"] = .integer(floor) }
        if let author = quote?["authorName"]?.string { arguments["replyToAuthor"] = .string(author) }
        if let nodes = quote?["nodes"] { arguments["replyToText"] = .string(ContentQuoteContext.text(nodes)) }
        if let time = quote?["createdAtTitle"]?.string { arguments["postedAt"] = .string(time) }
        return .compose(arguments)
    }
}

enum ContentQuoteContext {
    /// PostDetailScreen.excerpt: only top-level paragraphs/headings and text/link inlines.
    /// No truncation: the chip truncates visually, never the Markdown sent to the site.
    static func text(_ value: JSONValue) -> String {
        (value.array ?? []).compactMap { node -> String? in
            guard ["p", "h"].contains(node["type"]?.string ?? "") else { return nil }
            let text = (node["inlines"]?.array ?? []).compactMap { inline -> String? in
                ["t", "a"].contains(inline["type"]?.string ?? "") ? inline["text"]?.string : nil
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }
}

struct ContentFeedMemory {
    struct Position: Equatable { let postID: Int64; let page: Int64 }
    private struct Key: Hashable { let board: String; let sort: String }
    private var positions: [Key: Position] = [:]
    mutating func record(board: String, sort: String, postID: Int64, page: Int64?) {
        // Null is an unknown repository page, not page one. Keep the last restorable anchor.
        guard let page, page > 0 else { return }
        positions[Key(board: board, sort: sort)] = Position(postID: postID, page: page)
    }
    func position(board: String, sort: String) -> Position? { positions[Key(board: board, sort: sort)] }
}

enum ContentReactionPolicy {
    enum Decision { case signIn, send, confirm, disabled }
    static func decision(action: String, signedIn: Bool, spent: Bool) -> Decision {
        guard signedIn else { return .signIn }
        guard !spent else { return .disabled }
        switch action {
        case "Upvote": return .send
        case "ChickenLeg", "Dislike": return .confirm
        default: return .disabled
        }
    }
}

enum ContentNotificationAction {
    static func readArguments(_ row: JSONValue) throws -> [String: JSONValue] {
        guard let sources = row["sources"]?.array, !sources.isEmpty else {
            throw NativeFailure(code: "INVALID_DATA", message: "Missing notification sources")
        }
        return ["sources": .array(sources)]
    }
}

struct ContentPollSelection {
    private(set) var ids: Set<Int64> = []
    mutating func toggle(_ id: Int64, multiple: Bool) {
        if ids.contains(id) { ids.remove(id) }
        else if multiple { ids.insert(id) }
        else { ids = [id] }
    }
    mutating func reconcile(allowed: Set<Int64>, alreadyVoted: Bool, locked: Bool) {
        ids = alreadyVoted || locked ? [] : ids.intersection(allowed)
    }
}

struct ContentThreadOpening {
    let target: ContentReadingTarget
    let firstNewFloor: Int64?
    let needsLoad: Bool
    init(floor: String?, page: Int64?, status: JSONValue) {
        let seen = status["seenRepliesIfUnread"]?.int
        firstNewFloor = seen.flatMap { $0 > 0 && $0 < Int64(Int32.max) ? $0 + 1 : nil }
        target = ContentReadingTarget(floor: floor ?? (page == nil ? firstNewFloor.map { "#\($0)" } : nil), page: page)
        let first = status["firstLoadedPage"]?.int
        let last = status["lastLoadedPage"]?.int
        needsLoad = status["isThreadFresh"]?.bool != true || seen != nil || first == nil || last == nil || target.page < (first ?? 1) || target.page > (last ?? 1)
    }
}

struct ContentReadingTarget: Equatable, Hashable {
    let page: Int64
    let floor: String?
    init(floor: String?, page: Int64?) {
        if let floor, let n = Self.floorNumber(floor) {
            self.floor = floor
            self.page = n <= 0 ? 1 : (n - 1) / 10 + 1
        } else {
            self.floor = nil
            self.page = max(1, page ?? 1)
        }
    }
    init(visibleFloor: String?, page: Int64) {
        self.floor = visibleFloor
        self.page = max(1, page)
    }
    static func floorNumber(_ floor: String) -> Int64? {
        let trimmed = floor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32((trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed).trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return Int64(value)
    }
    func clamped(to total: Int64) -> Self {
        page > max(1, total) ? Self(floor: nil, page: max(1, total)) : self
    }
}

/// A jump within the loaded window is a scroll, not a repository replacement.
struct ContentThreadJump: Equatable {
    let target: ContentReadingTarget
    let loadPage: Int64?
    let extend: Bool
    let bottom: Bool
    init(target: ContentReadingTarget, thread: JSONValue, bottom: Bool = false) {
        let first = thread["firstLoadedPage"]?.int ?? 1
        let last = thread["lastLoadedPage"]?.int ?? 1
        let total = max(1, thread["totalPages"]?.int ?? 1)
        let comments = thread["comments"]?.array ?? []
        let pages = thread["commentPages"]?.array ?? []
        if let number = target.floor.flatMap(ContentReadingTarget.floorNumber),
           let index = comments.firstIndex(where: { $0["floor"]?.string.flatMap(ContentReadingTarget.floorNumber) == number }),
           pages.indices.contains(index), let page = pages[index].int {
            self.target = .init(visibleFloor: comments[index]["floor"]?.string, page: page)
        } else { self.target = target.clamped(to: total) }
        let missingOpening = self.target.floor.flatMap(ContentReadingTarget.floorNumber) == 0 && (thread["body"] == nil || thread["body"] == .null)
        loadPage = (thread == .null || missingOpening || self.target.page < first || self.target.page > last) ? self.target.page : nil
        extend = self.target.page == first - 1 || self.target.page == last + 1 || missingOpening
        self.bottom = bottom
    }
}

struct ContentJumpEntry {
    private(set) var text = ""
    private(set) var floor = false
    mutating func update(_ text: String) { self.text = String(text.filter { $0 >= "0" && $0 <= "9" }.prefix(6)) }
    mutating func toggleUnit() { floor.toggle(); text = "" }
    func target(total: Int64) -> ContentReadingTarget? {
        guard let number = Int32(text) else { return nil }
        return floor ? .init(floor: "#\(max(0, number))", page: nil).clamped(to: total)
            : .init(floor: nil, page: max(1, Int64(number))).clamped(to: total)
    }
}

/// Geometry callbacks belong to one observation, board/sort and identity generation.
struct ContentFeedTicket: Equatable {
    let generation: Int
    let board: String
    let sort: String
    let observation: UUID
}

struct ContentFeedVisibleRow: Equatable {
    let ticket: ContentFeedTicket
    let id: Int64
    let page: Int64?
    let frame: CGRect
}

/// Suppress repeated geometry deliveries while preserving row, page, and observation changes.
struct ContentFeedVisibleObservation {
    private struct Identity: Equatable {
        let ticket: ContentFeedTicket
        let id: Int64
        let page: Int64?
    }
    private var last: Identity?

    mutating func shouldPublish(_ row: ContentFeedVisibleRow, current: ContentFeedTicket) -> Bool {
        guard row.ticket == current else { return false }
        let identity = Identity(ticket: row.ticket, id: row.id, page: row.page)
        guard identity != last else { return false }
        last = identity
        return true
    }
}

enum ContentFeedViewport {
    static func firstVisible(_ rows: [ContentFeedVisibleRow], viewport: CGRect, ticket: ContentFeedTicket) -> ContentFeedVisibleRow? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        return rows.filter {
            $0.ticket == ticket && $0.frame.width > 0 && $0.frame.height > 0 &&
                $0.frame.intersects(viewport) && $0.frame.maxY > viewport.minY && $0.frame.minY < viewport.maxY
        }.min { $0.frame.minY == $1.frame.minY ? $0.id < $1.id : $0.frame.minY < $1.frame.minY }
    }
}

struct ContentFeedSheet {
    private(set) var owner: ContentFeedTicket?
    mutating func present(_ ticket: ContentFeedTicket) { owner = ticket }
    mutating func cancel() { owner = nil }
    mutating func take(_ page: Int64, current: ContentFeedTicket) -> Int64? {
        defer { owner = nil }
        return owner == current ? page : nil
    }
}

/// Follow finger travel, never row geometry (prefetch, relayout and scrollTo are not intent).
struct ContentFeedDirection {
    private(set) var expanded = true
    private var previous: CGFloat = 0
    private var travel: CGFloat = 0

    mutating func record(translation: CGFloat) {
        guard translation.isFinite else { return }
        let delta = translation - previous
        previous = translation
        guard delta != 0 else { return }
        // A reversal starts a fresh threshold; subthreshold jitter cannot flip the rail.
        if (delta > 0 && travel < 0) || (delta < 0 && travel > 0) { travel = 0 }
        travel += delta
        guard abs(travel) >= 40 else { return }
        expanded = travel > 0
        travel = 0
    }

    mutating func endGesture() {
        previous = 0
        travel = 0
    }
}

enum ContentFeedCompose: Equatable {
    case signIn
    case compose([String: JSONValue])
    static func resolve(signedIn: Bool, board: String) -> Self {
        signedIn ? .compose(board.isEmpty ? [:] : ["boardSlug": .string(board)]) : .signIn
    }
}

/// Navigation only: Kotlin still owns rows, load state and the append/prepend mechanism.
struct ContentFeedJump {
    enum Action: Equatable {
        case scroll(Int64)
        case access([String: JSONValue])
        case retry(String)
        case replace(Int64)
    }
    // Original PostListScreen.APPEND_WAIT_MILLIS, using monotonic rather than wall time.
    static let appendWait: TimeInterval = 15
    struct Wait: Equatable {
        let id = UUID()
        let deadline: TimeInterval
    }
    private(set) var wait: Wait?
    private(set) var pendingPage: Int64?
    private var pendingPager: String?
    // Monotonic time is injectable so navigation tests never sleep for a network deadline.
    private let uptime: () -> TimeInterval
    private let owner: ContentFeedTicket?
    init(owner: ContentFeedTicket? = nil, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.owner = owner
        self.uptime = uptime
    }

    mutating func request(_ requested: Int64, snapshot: JSONValue) throws -> Action {
        let window = try ContentPagingWindow(snapshot)
        let target = min(max(1, requested), max(1, snapshot["totalPages"]?.int ?? 1))
        cancel()
        if let row = window.rows.first(where: { $0.page == target }) { return .scroll(row.id) }
        if let last = window.rows.last, let page = last.page, page < Int64.max, target == page + 1,
           snapshot["append"]?["endOfPaginationReached"]?.bool != true,
           let arguments = window.accessArguments(for: last.id), let pagerID = window.pagerID {
            pendingPage = target
            pendingPager = pagerID
            wait = Wait(deadline: uptime() + Self.appendWait)
            if snapshot["append"]?["status"]?.string == "Error" { return .retry(pagerID) }
            return .access(arguments)
        }
        return .replace(target)
    }

    mutating func arrived(snapshot: JSONValue) throws -> Int64? {
        if case .scroll(let id) = try update(snapshot: snapshot) { return id }
        return nil
    }

    mutating func update(snapshot: JSONValue, current: ContentFeedTicket? = nil) throws -> Action? {
        guard let pendingPage else { return nil }
        guard owner == current else { cancel(); return nil }
        let window = try ContentPagingWindow(snapshot)
        guard window.pagerID == pendingPager else {
            // A bound observation replaced its pager. Unbound ID-only consumers can ignore
            // unrelated snapshots, but the UI must retire both the destination and timer.
            if owner != nil { cancel() }
            return nil
        }
        let action: Action
        if let row = window.rows.first(where: { $0.page == pendingPage }) { action = .scroll(row.id) }
        else if snapshot["append"]?["status"]?.string == "Error" {
            // Keep the destination for explicit Retry, but never retry/replace from a timer.
            wait = nil
            return nil
        }
        else if snapshot["append"]?["status"]?.string == "NotLoading",
                snapshot["append"]?["endOfPaginationReached"]?.bool == true { action = .replace(pendingPage) }
        else if let wait, remaining(wait) == 0 { action = .replace(pendingPage) }
        else { return nil }
        cancel()
        return action
    }

    func remaining(_ wait: Wait) -> TimeInterval { max(0, wait.deadline - uptime()) }

    mutating func timeout(_ expected: Wait, snapshot: JSONValue, current: ContentFeedTicket? = nil) throws -> Action? {
        guard wait == expected else { return nil }
        return try update(snapshot: snapshot, current: current)
    }

    mutating func cancel() {
        pendingPage = nil
        pendingPager = nil
        wait = nil
    }
}

/// A presenter snapshot is a replacement window, not an append-only collection.
struct ContentPagingWindow: Equatable {
    struct Row: Identifiable, Equatable {
        let id: Int64
        let globalIndex: Int64
        let page: Int64?
        let value: JSONValue
    }
    let pagerID: String?
    let rows: [Row]
    init(_ value: JSONValue) throws {
        if value == .null { pagerID = nil; rows = []; return }
        guard let id = value["pagerId"]?.string,
              let before = value["placeholdersBefore"]?.int, before >= 0,
              let after = value["placeholdersAfter"]?.int, after >= 0,
              let count = value["itemCount"]?.int,
              let items = value["items"]?.array,
              before <= Int64.max - Int64(items.count),
              after <= Int64.max - before - Int64(items.count),
              count == before + Int64(items.count) + after else {
            throw NativeFailure(code: "INVALID_DATA", message: "Invalid paging window")
        }
        var seen = Set<Int64>()
        rows = try items.enumerated().map { index, item in
            guard let postID = item["summary"]?["postId"]?.int, postID > 0,
                  seen.insert(postID).inserted else {
                throw NativeFailure(code: "INVALID_DATA", message: "Invalid post identity")
            }
            return Row(id: postID, globalIndex: before + Int64(index), page: item["page"]?.int, value: item)
        }
        pagerID = id
    }
    func accessArguments(for postID: Int64) -> [String: JSONValue]? {
        guard let pagerID, let row = rows.first(where: { $0.id == postID }) else { return nil }
        return ["pagerId": .string(pagerID), "index": .integer(row.globalIndex)]
    }
}
