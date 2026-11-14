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
    private var lastRevision: UUID?

    init(mode: EditorMode, transport: any NativeTransport, arguments: [String: JSONValue]) {
        session = EditorSession(mode: mode, transport: transport)
        session.replyContext = ["replyToFloor": arguments["quotedFloor"] ?? .null,
                                "replyToAuthor": arguments["replyToAuthor"] ?? .null,
                                "replyToText": arguments["replyToText"] ?? .null]
        if case .reply = mode {
            let author = arguments["replyToAuthor"]?.string
            let quote = arguments["replyToText"]?.string
            let initial = (author.map { "@\($0) " } ?? "") + (quote.map { "\n" + $0.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n" } ?? "")
            session.body = EditorBuffer(text: initial, selection: NSRange(location: initial.utf16.count, length: 0))
            quotePrefix = initial.isEmpty ? nil : initial
        }
        session.onChange = { [weak self] in self?.changed() }
    }
    private func changed() {
        objectWillChange.send()
        guard lastRevision != session.revision else { return }
        lastRevision = session.revision
        debounce?.cancel()
        guard ready, !session.accepted else { return }
        debounce = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            guard let self else { return }
            self.session.saveDraft()
            do { try await self.session.drafts.flush() } catch { self.report(error) }
        }
    }
    func load() async {
        guard !ready else { return }
        let token = epoch
        do { try await session.load(); guard token == epoch else { return }; ready = true; failure = nil }
        catch { if token == epoch { report(error) } }
    }
    func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        failure = error as? NativeFailure ?? NativeFailure(code: "INTERNAL", message: "Operation could not be completed")
    }
    func flush() async throws {
        debounce?.cancel()
        if ready, !session.accepted { session.saveDraft() }
        try await session.drafts.flush()
    }
    func showPreview() async {
        let token = epoch
        let revision = session.revision
        previewing = true; preview = nil
        do {
            let value = try await session.transport.request("editor.preview", ["body": .string(session.body.text)])
            let nodes = try JSONDecoder().decode([NativeRichNode].self, from: JSONEncoder().encode(value))
            guard token == epoch, revision == session.revision else { return }
            preview = nodes
        } catch { if token == epoch { report(error) } }
    }
    func submit() async {
        guard ready else { return }
        debounce?.cancel()
        failure = nil
        let token = epoch
        do {
            let result = try await session.submit()
            guard token == epoch else { return }
            acceptedResult = result
            if session.accepted, case .message = session.mode { quotePrefix = nil }
        } catch { if token == epoch { report(error) } }
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
    func addFile(_ url: URL) {
        guard attachments.count < 8 else { try? FileManager.default.removeItem(at: url); return }
        do { attachments.append(try EditorAttachment(source: url, name: url.lastPathComponent)) }
        catch { report(error) }
    }
    func upload(_ id: UUID) {
        guard uploads[id] == nil, let index = attachments.firstIndex(where: { $0.id == id }),
              attachments[index].phase == .waiting || attachments[index].phase == .failed else { return }
        let attempt = attachments[index].begin()
        let item = attachments[index]
        let token = epoch
        uploads[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.uploads[id] = nil }
            do {
                let value = try await self.session.transport.request("editor.image.upload", ["id": .string(id.uuidString), "source": .string(item.source.absoluteString), "name": .string(item.name)])
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
        uploads[id]?.cancel()
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let item = attachments[index]
        attachments[index].remove()
        attachments.remove(at: index)
        try? FileManager.default.removeItem(at: item.source)
        // Uploaded remote files are never deleted implicitly. Inserted Markdown remains user-owned text.
    }
    func invalidate() {
        epoch = UUID(); debounce?.cancel(); uploads.values.forEach { $0.cancel() }; uploads = [:]
        attachments.forEach { try? FileManager.default.removeItem(at: $0.source) }; attachments = []
        session.invalidate(); quotePrefix = nil; preview = nil; previewing = false; ready = false; failure = nil; acceptedResult = nil
    }
}
