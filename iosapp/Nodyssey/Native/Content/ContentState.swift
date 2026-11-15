import Foundation
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
