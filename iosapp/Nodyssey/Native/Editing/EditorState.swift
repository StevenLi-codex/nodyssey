import Foundation
import NodysseyNativeCore

enum EditorMode: Equatable, Sendable {
    case post
    case reply(postID: Int64)
    case edit(postID: Int64, commentID: Int64, page: Int64, opening: Bool)
    case message(uid: Int64)

    static func route(_ route: String, _ args: [String: JSONValue]) throws -> Self {
        let failure = NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid editor destination")
        func id(_ key: String) throws -> Int64 {
            guard let value = args[key]?.int, value > 0 else { throw failure }
            return value
        }
        if route == "MessageThread" { return .message(uid: try id("uid")) }
        guard route == "PostComposer" else { throw failure }
        if args["edit"]?.bool == true {
            guard args["reply"]?.bool != true, let opening = args["isOpeningPost"]?.bool else { throw failure }
            let page = args["page"]?.int ?? 1
            guard page > 0 else { throw failure }
            return .edit(postID: try id("postId"), commentID: try id("commentId"), page: page, opening: opening)
        }
        if args["reply"]?.bool == true { return .reply(postID: try id("postId")) }
        guard args["postId"] == nil, args["commentId"] == nil else { throw failure }
        return .post
    }
    var surface: String {
        switch self { case .post: return "POST"; case .message: return "MESSAGE"; case .reply: return "REPLY"; case .edit(_, _, _, let opening): return opening ? "POST" : "REPLY" }
    }
    var showsTitle: Bool { surface == "POST" }
    var identity: [String: JSONValue] {
        switch self {
        case .post: return [:]
        case .reply(let id): return ["postId": .integer(id)]
        case .message(let id): return ["uid": .integer(id)]
        case .edit(let id, let comment, let page, let opening):
            return ["postId": .integer(id), "commentId": .integer(comment), "page": .integer(page), "isOpeningPost": .bool(opening)]
        }
    }
}

/// In-memory only: the shared repository exposes no message draft persistence API.
@MainActor enum MessageDraftMemory {
    static var generation: Int?
    struct Draft { let buffer: EditorBuffer; let quote: String?; let revision: UUID }
    static var values: [Int64: Draft] = [:]
    static func align(_ value: Int) { if generation != value { values = [:]; generation = value } }
}

@MainActor final class EditorSession {
    let mode: EditorMode
    let transport: any NativeTransport
    var body = EditorBuffer()
    var title = EditorBuffer()
    var permission: Int64 = 0
    var boardSlug: String?
    var boardTitle: String?
    var replyContext: [String: JSONValue] = [:]
    private(set) var pendingRestore: JSONValue?
    private(set) var revision = UUID()
    private var hasUserEdits = false
    private var generation = UUID()
    var onChange: (() -> Void)?

    let mutation = NativeMutationState()
    lazy var drafts = EditorDraftQueue(transport: transport)
    private(set) var busy = false
    private(set) var accepted = false
    var markdown = true

    init(mode: EditorMode, transport: any NativeTransport) { self.mode = mode; self.transport = transport }
    func changeBody(_ value: EditorBuffer) {
        guard body != value else { return }
        let textChanged = body.text != value.text
        body = value
        if textChanged { changed() } else { onChange?() }
    }
    func changed() { hasUserEdits = true; revision = UUID(); mutation.draft = body.text; accepted = false; onChange?() }
    func saveDraft() {
        guard pendingRestore == nil else { return }
        var args = mode.identity
        args["body"] = .string(body.text)
        switch mode {
        case .post:
            args["title"] = .string(title.text)
            args["permission"] = .integer(permission)
            args["boardSlug"] = boardSlug.map(JSONValue.string) ?? .null
            args["boardTitle"] = boardTitle.map(JSONValue.string) ?? .null
            drafts.save("draft.post.save", args)
        case .reply:
            args.merge(replyContext) { _, new in new }
            drafts.save("draft.comment.save", args)
        case .edit, .message: break // No shared persistent store for these modes.
        }
    }
    func submit() async throws -> JSONValue {
        guard !busy else { throw NativeFailure(code: "IN_FLIGHT", message: "Submission in progress") }
        guard !accepted else { throw NativeFailure(code: "ALREADY_ACCEPTED", message: "Submission already accepted") }
        guard !body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "Body is required")
        }
        var args = mode.identity
        let operation: String
        let key: String
        switch mode {
        case .post:
            guard !title.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let boardSlug, !boardSlug.isEmpty else {
                throw NativeFailure(code: "INVALID_ARGUMENT", message: "Title and board are required")
            }
            operation = "editor.post.publish"; key = "body"
            args["title"] = .string(title.text); args["boardSlug"] = .string(boardSlug); args["permission"] = .integer(permission)
        case .reply:
            operation = "editor.comment.publish"; key = "body"
            args["quotedFloor"] = replyContext["replyToFloor"] ?? .null
        case .edit:
            operation = "editor.edit.save"; key = "body"
            args["title"] = .string(title.text); args["permission"] = .integer(permission)
        case .message:
            operation = "messages.send"; key = "content"; args["markdown"] = .bool(markdown)
        }
        let token = generation
        let sentRevision = revision
        let submitted = body.text
        busy = true; onChange?()
        defer { if token == generation { busy = false; onChange?() } }
        saveDraft()
        try await drafts.flush()
        guard token == generation else { throw CancellationError() }
        mutation.draft = submitted
        let result = try await mutation.submit(using: transport, operation: operation, arguments: args, draftKey: key)
        guard token == generation else { throw CancellationError() }
        accepted = sentRevision == revision
        // Never synthesize a message/floor ID; null is accepted with unresolved identity.
        if sentRevision == revision, case .message = mode { body = EditorBuffer() }
        return result
    }
    func invalidate() {
        generation = UUID(); mutation.invalidate(); drafts.invalidate()
        body = EditorBuffer(); title = EditorBuffer(); pendingRestore = nil
        boardSlug = nil; boardTitle = nil; replyContext = [:]; busy = false; accepted = false
        hasUserEdits = false; revision = UUID(); onChange?()
    }
    func load() async throws {
        let token = generation
        let initial = revision
        let operation: String
        switch mode {
        case .post: operation = "draft.post.get"
        case .reply: operation = "draft.comment.get"
        case .edit: operation = "editor.edit.load"
        case .message: return
        }
        let value = try await transport.request(operation, mode.identity)
        guard token == generation else { throw CancellationError() }
        guard value != .null else { return }
        if case .edit = mode, initial == revision, !hasUserEdits { restore(value) }
        else { pendingRestore = value; onChange?() }
    }
    func keepCurrent() { pendingRestore = nil; onChange?() }
    func deleteDraft() async throws {
        let operation: String
        let read: String
        switch mode {
        case .post: operation = "draft.post.delete"; read = "draft.post.get"
        case .reply: operation = "draft.comment.delete"; read = "draft.comment.get"
        case .edit, .message: pendingRestore = nil; return
        }
        drafts.save(operation, mode.identity)
        try await drafts.flush()
        let value = try await transport.request(read, mode.identity)
        guard value == .null else { throw NativeFailure(code: "DRAFT_CHANGED", message: "Draft changed") }
        pendingRestore = nil; onChange?()
    }
    func restore(_ value: JSONValue) {
        body = EditorBuffer(text: value["body"]?.string ?? "")
        title = EditorBuffer(text: value["title"]?.string ?? "")
        permission = value["permission"]?.int ?? 0
        boardSlug = value["boardSlug"]?.string
        boardTitle = value["boardTitle"]?.string
        if case .reply = mode {
            replyContext = ["replyToFloor": value["replyToFloor"] ?? .null,
                            "replyToAuthor": value["replyToAuthor"] ?? .null,
                            "replyToText": value["replyToText"] ?? .null]
        }
        pendingRestore = nil
        hasUserEdits = false
        revision = UUID()
        onChange?()
    }
}

/// Save calls form one chain, including deletion. Flush follows newly enqueued work.
@MainActor final class EditorDraftQueue {
    private let transport: any NativeTransport
    private var tail: Task<Void, Error>?
    private var jobs: [UUID: Task<Void, Error>] = [:]
    private var generation = UUID()
    private var sequence = 0
    init(transport: any NativeTransport) { self.transport = transport }
    func save(_ operation: String, _ arguments: [String: JSONValue]) {
        let previous = tail
        let token = generation
        sequence += 1
        let id = UUID()
        let pending = Task { [self] in
            defer { jobs[id] = nil }
            _ = await previous?.result
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            _ = try await transport.request(operation, arguments)
        }
        jobs[id] = pending
        tail = pending
    }
    func flush() async throws {
        while true {
            let current = sequence
            try await tail?.value
            if current == sequence { return }
        }
    }
    func invalidate() {
        generation = UUID()
        jobs.values.forEach { $0.cancel() }
        jobs = [:]; tail = nil
    }
}

struct EditorAttachment: Identifiable, Sendable {
    enum Phase: String, Sendable { case waiting, uploading, uploaded, failed, removed }
    let id = UUID()
    let source: URL
    let name: String
    private(set) var phase: Phase = .waiting
    private(set) var markdown: String?
    private var attempt = UUID()
    init(source: URL, name: String) throws {
        guard source.isFileURL else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "Local file required") }
        self.source = source; self.name = name
    }
    mutating func begin() -> UUID { attempt = UUID(); phase = .uploading; return attempt }
    mutating func complete(_ token: UUID, markdown: String) {
        guard phase == .uploading, token == attempt else { return }
        self.markdown = markdown; phase = .uploaded
    }
    mutating func fail(_ token: UUID) { if phase == .uploading, token == attempt { phase = .failed } }
    mutating func remove() { attempt = UUID(); phase = .removed; markdown = nil }
}

enum EditorMarkup {
    // Exact StardustReceiveMarkup.marker / JavaScript encodeURIComponent wire spelling.
    static func receive(member: Int64, reference: Int64, amount: Int64, description: String, onetime: Bool) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let encoded = description.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return " nsapp://stardust-receive?member_id=\(member)&ref_id=\(reference)&description=\(encoded)&diff=\(amount)&onetime=\(onetime) "
    }
}

@MainActor protocol EditorInput: AnyObject {
    func commitMarkedText()
    func snapshot()
    func blur()
}
@MainActor enum EditorHandoff {
    static func perform(_ fields: [any EditorInput], action: () -> Void) {
        fields.forEach { $0.commitMarkedText() }
        fields.forEach { $0.snapshot() }
        fields.forEach { $0.blur() }
        action()
    }
}

struct EditorBuffer: Equatable, Sendable {
    var text: String = ""
    var selection: NSRange = NSRange(location: 0, length: 0)
    mutating func removePrefixIfUnchanged(_ prefix: String) {
        guard !prefix.isEmpty, text.hasPrefix(prefix) else { return }
        let end = min(text.utf16.count, selection.location + selection.length)
        let offset = prefix.utf16.count
        text.removeFirst(prefix.count)
        let start = max(0, selection.location - offset)
        selection = NSRange(location: start, length: max(0, end - offset - start))
    }
    mutating func wrap(prefix: String, suffix: String) {
        guard let range = Range(selection, in: text) else { return }
        let selected = String(text[range])
        text.replaceSubrange(range, with: prefix + selected + suffix)
        selection = NSRange(location: selection.location + prefix.utf16.count, length: selected.utf16.count)
    }
    mutating func insert(_ value: String) {
        guard let range = Range(selection, in: text) else { return }
        text.replaceSubrange(range, with: value)
        selection = NSRange(location: selection.location + value.utf16.count, length: 0)
    }
}
