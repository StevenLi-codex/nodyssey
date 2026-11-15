import SwiftUI
import NodysseyNativeCore

@MainActor final class EditorViewModel: ObservableObject {
    let session: EditorSession
    let focus = EditorFocus()
    @Published var failure: NativeFailure?
    @Published var ready = false
    @Published var preview: [NativeRichNode]?
    @Published var previewing = false
    @Published var attachments: [EditorAttachment] = []
    @Published var acceptedResult: JSONValue?
    @Published var quotePrefix: String?
    private var epoch = UUID()
    private var debounce: Task<Void, Never>?
    private var uploads: [UUID: Task<Void, Never>] = [:]
    private var fileLeases: [UUID: EditorSourceLease] = [:]
    private var lastRevision: UUID?
    private var messageGeneration: Int?
    private var initializedMessage = false
    private(set) var isClosed = false
    private var teardown: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private struct DepartureInput: Equatable {
        let epoch: UUID
        let revision: UUID
        let body: String
        let title: String
        let permission: Int64
        let boardSlug: String?
        let boardTitle: String?
        let replyContext: [String: JSONValue]
        let pendingRestore: JSONValue?
        let markdown: Bool
        let accepted: Bool
        let quote: String?
        let attachments: [UUID]
    }
    private var departureInput: DepartureInput {
        DepartureInput(epoch: epoch, revision: session.revision, body: session.body.text,
                       title: session.title.text, permission: session.permission,
                       boardSlug: session.boardSlug, boardTitle: session.boardTitle,
                       replyContext: session.replyContext, pendingRestore: session.pendingRestore,
                       markdown: session.markdown, accepted: session.accepted, quote: quotePrefix,
                       attachments: attachments.map(\.id))
    }
    private var preparedInput: DepartureInput?

    init(mode: EditorMode, transport: any NativeTransport, arguments: [String: JSONValue]) {
        session = EditorSession(mode: mode, transport: transport)
        session.replyContext = ["replyToFloor": arguments["quotedFloor"] ?? .null,
                                "replyToAuthor": arguments["replyToAuthor"] ?? .null,
                                "replyToText": arguments["replyToText"] ?? .null]
        session.onChange = { [weak self] in self?.changed() }
    }
    private func changed() {
        objectWillChange.send()
        guard lastRevision != session.revision else { return }
        lastRevision = session.revision
        debounce?.cancel()
        guard !isClosed, ready, !session.accepted else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            guard let self else { return }
            self.session.saveDraft()
            do { try await self.session.drafts.flush() } catch { self.report(error) }
        }
    }
    func appear(generation: Int) async {
        guard !isClosed else { return }
        MessageDraftMemory.align(generation)
        messageGeneration = generation
        // Consume once, synchronously before load yields. A returning tab still
        // owns its live buffer, including the accepted revision and newer input.
        if !initializedMessage {
            initializedMessage = true
            if case .message(let uid) = session.mode,
               let draft = MessageDraftMemory.values.removeValue(forKey: uid) {
                session.changeBody(draft.buffer); quotePrefix = draft.quote
            }
        }
        await load()
    }
    func cacheMessage() {
        guard !isClosed, messageGeneration == MessageDraftMemory.generation else { return }
        if case .message(let uid) = session.mode {
            MessageDraftMemory.values[uid] = .init(buffer: session.body, quote: quotePrefix, revision: session.revision)
        }
    }
    func load() async {
        guard !isClosed, !ready else { return }
        let token = epoch
        await startOwnedTask { [self] in
            guard !isClosed, !Task.isCancelled else { return }
            do { try await session.load(); guard token == epoch else { return }; ready = true; failure = nil }
            catch { if token == epoch { report(error) } }
        }.value
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        failure = error as? NativeFailure ?? NativeFailure(code: "INTERNAL", message: "Operation could not be completed")
    }
    enum CloseDecision { case restore, keepCurrent, discardCurrent }
    func close(decision: CloseDecision? = nil) async throws {
        if isClosed { await teardown?.value; return }
        try await prepareForDeparture(decision: decision)
        guard isDeparturePreparationValid else {
            throw NativeFailure(code: "DRAFT_CHANGED", message: "Input changed while saving; close again to save the latest input")
        }
        terminateAfterPrepared()
        await teardown?.value
    }
    func prepareForDeparture(decision: CloseDecision? = nil) async throws {
        preparedInput = nil
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        guard !session.busy else { throw NativeFailure(code: "IN_FLIGHT", message: "Submission in progress") }
        debounce?.cancel()
        let discard: Bool
        switch decision {
        case .restore:
            guard let saved = session.pendingRestore else { throw NativeFailure(code: "DRAFT_CHANGED", message: "Stored draft changed") }
            session.restore(saved)
            discard = false
        case .keepCurrent:
            session.keepCurrent()
            discard = false
        case .discardCurrent:
            if case .edit = session.mode { discard = true }
            else {
                guard ready, session.pendingRestore != nil else { throw NativeFailure(code: "DRAFT_DECISION_REQUIRED", message: "Load the stored draft before deciding") }
                discard = true
            }
        case nil: discard = false
        }
        let token = epoch
        let input = departureInput
        if discard { try await session.drafts.flush() }
        else { try await flush() }
        guard token == epoch, !Task.isCancelled else { throw CancellationError() }
        guard input == departureInput, !session.busy else {
            throw NativeFailure(code: "DRAFT_CHANGED", message: "Input changed while saving; close again to save the latest input")
        }
        preparedInput = input
    }
    var isDeparturePreparationValid: Bool {
        !isClosed && !session.busy && preparedInput == departureInput
    }
    func terminateAfterPrepared() {
        guard isDeparturePreparationValid else { return }
        preparedInput = nil
        cacheMessage()
        invalidate()
    }
    func flush() async throws {
        guard !isClosed else { throw CancellationError() }
        debounce?.cancel()
        // A successful flush authorizes permanent dismissal. Never report success
        // while the persisted draft is unknown or the user has not chosen a buffer.
        switch session.mode {
        case .post, .reply:
            guard ready else { throw NativeFailure(code: "DRAFT_NOT_READY", message: "Wait for the draft to load, or retry loading before closing") }
        case .edit, .message: break
        }
        guard session.pendingRestore == nil else {
            throw NativeFailure(code: "DRAFT_DECISION_REQUIRED", message: "Choose restore, keep current, or discard before closing")
        }
        if ready, !session.accepted { session.saveDraft() }
        try await session.drafts.flush()
    }
    func showPreview() async {
        guard !isClosed else { return }
        let token = epoch
        let revision = session.revision
        let body = session.body.text
        previewing = true; preview = nil
        await startOwnedTask { [self] in
            guard !isClosed, !Task.isCancelled else { return }
            do {
                let value = try await session.transport.request("editor.preview", ["body": .string(body)])
                let nodes = try JSONDecoder().decode([NativeRichNode].self, from: JSONEncoder().encode(value))
                guard token == epoch, revision == session.revision else { return }
                preview = nodes
            } catch { if token == epoch { report(error) } }
        }.value
    }
    func submit() async {
        guard ready else { return }
        debounce?.cancel()
        failure = nil
        let token = epoch
        let submittedRevision = session.revision
        do {
            let result = try await session.submit()
            guard token == epoch else { return }
            if case .message(let uid) = session.mode,
               messageGeneration == MessageDraftMemory.generation,
               MessageDraftMemory.values[uid]?.revision == submittedRevision {
                MessageDraftMemory.values[uid] = nil
            }
            acceptedResult = result
            if session.accepted, case .message = session.mode { quotePrefix = nil }
        } catch { if token == epoch { report(error) } }
    }
    func consumeAcceptedReply(revision: UUID) async throws -> Bool {
        guard session.accepted, session.revision == revision else { return false }
        debounce?.cancel()
        let cleared = try await session.consumeAcceptedReply(revision: revision)
        if cleared { debounce?.cancel() }
        return cleared
    }
    func quote(_ text: String) {
        focus.handoff {
            var buffer = session.body
            if let quotePrefix { buffer.removePrefixIfUnchanged(quotePrefix) }
            let prefix = text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            buffer.text = prefix + buffer.text
            buffer.selection.location += prefix.utf16.count
            quotePrefix = prefix
            session.changeBody(buffer)
        }
    }
    func removeQuote() {
        focus.handoff {
            var buffer = session.body
            if let quotePrefix { buffer.removePrefixIfUnchanged(quotePrefix) }
            quotePrefix = nil; session.replyContext = [:]
            session.changeBody(buffer); session.changed()
        }
    }
    func clearReplyTarget() {
        focus.handoff { session.replyContext = [:]; session.changed() }
    }
    func applyReply(arguments: [String: JSONValue], quoting: Bool) {
        guard case .reply(let postID) = session.mode,
              let floor = arguments["quotedFloor"]?.int, Int32(exactly: floor) != nil else { return }
        focus.handoff {
            let author = arguments["replyToAuthor"]?.string ?? ""
            let excerpt = arguments["replyToText"]?.string ?? ""
            if quoting {
                let reference = "@\(author) [#\(floor)](/post-\(postID)-1#\(floor))"
                let time = arguments["postedAt"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                let block = "> " + reference + (time.map { " 发布于" + $0 } ?? "") + "\n> " + excerpt.replacingOccurrences(of: "\n", with: "\n> ") + "\n\n"
                var buffer = session.body
                // appendBlock: keep quoted floors cumulative ordinary editable Markdown.
                if !buffer.text.isEmpty && !buffer.text.hasSuffix("\n\n") {
                    buffer.text += buffer.text.hasSuffix("\n") ? "\n" : "\n\n"
                }
                buffer.text += block
                buffer.selection = NSRange(location: buffer.text.utf16.count, length: 0)
                session.changeBody(buffer)
            } else {
                session.replyContext = ["replyToFloor": .integer(floor), "replyToAuthor": .string(author), "replyToText": .string(excerpt)]
                session.changed()
            }
        }
    }
    func insert(_ markdown: String) {
        focus.handoff {
            var buffer = session.body
            buffer.insert(markdown)
            session.changeBody(buffer)
        }
    }
    func wrap(_ prefix: String, _ suffix: String) {
        focus.handoff {
            var buffer = session.body
            buffer.wrap(prefix: prefix, suffix: suffix)
            session.changeBody(buffer)
        }
        focus.refocus()
    }
    /// The editor, not a disappearing picker coordinator, owns the copy loop.
    /// A provider may finish after cancellation: its returned owned copy must be
    /// deleted, never attached. Never begin the next provider after dismissal.
    func importFiles(_ copies: [@MainActor () async throws -> URL]) {
        guard !isClosed else { return }
        startOwnedTask { [self] in
            for copy in copies.prefix(8) {
                guard !isClosed, !Task.isCancelled else { return }
                do {
                    let url = try await copy()
                    guard !isClosed, !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    addFile(url)
                } catch {
                    guard !isClosed, !Task.isCancelled else { return }
                    report(NativeFailure(code: "IMAGE_UNAVAILABLE", message: "Image could not be imported"))
                }
            }
        }
    }
    func addFile(_ url: URL) {
        guard !isClosed, attachments.count < 8 else { try? FileManager.default.removeItem(at: url); return }
        do {
            let item = try EditorAttachment(source: url, name: url.lastPathComponent)
            fileLeases[item.id] = EditorSourceLease(url)
            attachments.append(item)
        }
        catch { try? FileManager.default.removeItem(at: url); report(error) }
    }
    func upload(_ id: UUID) {
        guard uploads[id] == nil, let index = attachments.firstIndex(where: { $0.id == id }),
              attachments[index].phase == .waiting || attachments[index].phase == .failed else { return }
        guard let lease = fileLeases[id], let terminated = lease.acquire() else { return }
        let attempt = attachments[index].begin()
        let item = attachments[index]
        let token = epoch
        uploads[id] = Task { [weak self] in
            guard let self else { terminated(); return }
            defer { self.uploads[id] = nil }
            guard !Task.isCancelled else { terminated(); return }
            do {
                let value = try await self.session.transport.request("editor.image.upload", ["id": .string(id.uuidString), "source": .string(item.source.absoluteString), "name": .string(item.name)], onTermination: terminated)
                guard token == self.epoch, let index = self.attachments.firstIndex(where: { $0.id == id }) else { return }
                guard value["id"]?.string == id.uuidString, let markdown = value["markdown"]?.string, !markdown.isEmpty else {
                    throw NativeFailure(code: "INVALID_DATA", message: "Upload response is incomplete")
                }
                self.attachments[index].complete(attempt, markdown: markdown)
            } catch {
                guard token == self.epoch, let index = self.attachments.firstIndex(where: { $0.id == id }) else { return }
                self.attachments[index].fail(attempt); self.report(error)
            }
        }
    }
    func removeAttachment(_ id: UUID) {
        let consumer = uploads[id]
        consumer?.cancel()
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].remove()
        attachments.remove(at: index)
        fileLeases.removeValue(forKey: id)?.requestRemoval()
        // Uploaded remote files are never deleted implicitly. Inserted Markdown remains user-owned text.
    }
    @discardableResult
    private func startOwnedTask(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [self] in
            defer { ownedTasks[id] = nil }
            await operation()
        }
        ownedTasks[id] = task
        return task
    }
    func invalidate() {
        guard !isClosed else { return }
        preparedInput = nil
        isClosed = true
        epoch = UUID(); debounce?.cancel()
        let consumers = Array(uploads.values) + Array(ownedTasks.values)
        consumers.forEach { $0.cancel() }
        let leases = Array(fileLeases.values)
        fileLeases = [:]
        attachments = []
        // UI teardown need not wait for Kotlin. Only independently acknowledged
        // Job termination may release a source lease, including after this model dies.
        leases.forEach { $0.requestRemoval() }
        teardown = Task {
            for consumer in consumers { await consumer.value }
        }
        session.invalidate(); quotePrefix = nil; preview = nil; previewing = false; ready = false; failure = nil; acceptedResult = nil
    }
}

/// A thread owns this object, not the transient sheet. Navigation registers its
/// two-phase departure callbacks against the real thread destination identity.
@MainActor final class EditorReplyLifetime: ObservableObject {
    @Published private(set) var model: EditorViewModel?
    @Published var visible = false
    @Published var previewVisible = false
    @Published private(set) var closing = false
    @Published private(set) var initialFocusAllowed = false
    private var initialLoad = true
    private var epoch = UUID()
    private var opening = false
    private var closed = false
    private var pendingReply: (arguments: [String: JSONValue], quoting: Bool)?

    func open(postID: Int64, transport: any NativeTransport, generation: Int,
              arguments: [String: JSONValue] = [:], quoting: Bool = false) async {
        guard !closed, !opening, !closing else { return }
        if pendingReply == nil || !arguments.isEmpty { pendingReply = (arguments, quoting) }
        opening = true
        defer { opening = false }
        if model == nil { model = EditorViewModel(mode: .reply(postID: postID), transport: transport, arguments: [:]) }
        guard let model, !model.isClosed else { return }
        let token = epoch
        visible = true
        await model.appear(generation: generation)
        if token == epoch, !model.ready { initialLoad = false }
        guard token == epoch, !Task.isCancelled, model.ready else { return }
        if model.session.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let draft = model.session.pendingRestore { model.session.restore(draft) }
        if let pendingReply {
            self.pendingReply = nil
            model.applyReply(arguments: pendingReply.arguments, quoting: pendingReply.quoting)
        }
        if initialLoad { initialFocusAllowed = true; initialLoad = false }
    }
    /// Returns only an acknowledged server outcome, including an unresolved null floor.
    /// Local cleanup failure is displayed separately and never retries the publish.
    func publish() async -> JSONValue? {
        guard !closed, !closing, let model, model.ready, !model.session.busy,
              model.session.pendingRestore == nil, model.attachments.isEmpty else { return nil }
        model.focus.handoff {}
        let token = epoch
        let revision = model.session.revision
        model.acceptedResult = nil
        await model.submit()
        guard token == epoch, let result = model.acceptedResult else { return nil }
        do {
            if try await model.consumeAcceptedReply(revision: revision) {
                visible = false; previewVisible = false
                model.previewing = false; model.preview = nil
            }
        } catch { model.report(error) }
        guard token == epoch else { return nil }
        return result
    }
    @discardableResult
    func hide() async -> Bool {
        guard await prepareDeparture() else { return false }
        visible = false; previewVisible = false
        model?.previewing = false; model?.preview = nil
        return true
    }
    func prepareDeparture() async -> Bool {
        guard !closed, !closing else { return false }
        guard let model else { return true }
        closing = true
        let token = epoch
        defer { closing = false }
        model.focus.handoff {}
        do {
            try await model.prepareForDeparture()
            return token == epoch && !closed && !Task.isCancelled
        } catch {
            guard token == epoch, !closed, !Task.isCancelled else { return false }
            model.report(error); visible = true; return false
        }
    }
    var isDeparturePreparationValid: Bool { !closed && (model == nil || model?.isDeparturePreparationValid == true) }
    func terminateAfterPrepared() {
        guard isDeparturePreparationValid else { return }
        model?.terminateAfterPrepared()
        closed = true; epoch = UUID(); visible = false; previewVisible = false
    }
    func invalidate() {
        closed = true; epoch = UUID(); visible = false; previewVisible = false
        pendingReply = nil
        model?.invalidate()
    }
}

/// File ownership is separate from the cancellable UI continuation. A transport
/// without drain support leaks the copy safely rather than racing a live reader.
private final class EditorSourceLease: @unchecked Sendable {
    private let lock = NSLock()
    private let source: URL
    private var consumers: Set<UUID> = []
    private var removalRequested = false
    init(_ source: URL) { self.source = source }

    func acquire() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }
        guard !removalRequested else { return nil }
        let id = UUID()
        consumers.insert(id)
        return { [self] in
            lock.lock(); defer { lock.unlock() }
            guard consumers.remove(id) != nil else { return }
            removeIfDrained()
        }
    }

    func requestRemoval() {
        lock.lock(); defer { lock.unlock() }
        removalRequested = true
        removeIfDrained()
    }

    private func removeIfDrained() {
        if removalRequested && consumers.isEmpty { try? FileManager.default.removeItem(at: source) }
    }
}
