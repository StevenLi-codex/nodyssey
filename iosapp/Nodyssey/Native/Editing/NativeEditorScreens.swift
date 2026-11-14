import SwiftUI
import NodysseyNativeCore

func EL(_ key: String) -> String { NSLocalizedString(key, tableName: "Editor", bundle: .main, comment: "") }

@MainActor enum NativeEditorScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        guard ["PostComposer", "MessageThread"].contains(destination.route) else { return nil }
        do {
            let mode = try EditorMode.route(destination.route, destination.arguments)
            return AnyView(EditorEntry(mode: mode, arguments: destination.arguments))
        } catch {
            return AnyView(NativeFailureView(failure: error as? NativeFailure ?? NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid editor destination")))
        }
    }
}

private struct EditorEntry: View {
    @EnvironmentObject private var app: NativeAppModel
    let mode: EditorMode
    let arguments: [String: JSONValue]
    var body: some View { EditorHost(mode: mode, arguments: arguments, transport: app.transport).id(app.generation) }
}

/// In-memory only: the shared repository exposes no message/edit draft persistence API.
@MainActor private enum MessageDraftMemory {
    static var generation: Int?
    struct Draft { let buffer: EditorBuffer; let quote: String? }
    static var values: [Int64: Draft] = [:]
    static func align(_ value: Int) { if generation != value { values = [:]; generation = value } }
}

private struct EditorHost: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: EditorViewModel
    @StateObject private var boards = NativeStore()
    @StateObject private var permissions = NativeStore()
    @StateObject private var profile = NativeStore()
    @StateObject private var recentBoards = NativeStore()
    @State private var generation: Int?
    @State private var sheet: EditorPanel?
    @State private var showPhotos = false
    @State private var confirmPublish = false
    @State private var confirmDelete = false
    @State private var confirmRestore = false
    @State private var confirmClose = false
    @State private var closing = false
    let arguments: [String: JSONValue]

    init(mode: EditorMode, arguments: [String: JSONValue], transport: any NativeTransport) {
        _model = StateObject(wrappedValue: EditorViewModel(mode: mode, transport: transport, arguments: arguments))
        self.arguments = arguments
    }
    private var session: EditorSession { model.session }
    private var isMessage: Bool { if case .message = session.mode { return true }; return false }
    private var titleBinding: Binding<EditorBuffer> {
        Binding(get: { session.title }, set: { value in
            let changed = session.title.text != value.text
            session.title = value
            if changed { session.changed() }
        })
    }
    private var bodyBinding: Binding<EditorBuffer> { Binding(get: { session.body }, set: session.changeBody) }

    var body: some View {
        VStack(spacing: 0) {
            if case .message(let uid) = session.mode {
                EditorMessageThread(uid: uid, model: model)
            }
            if !model.ready {
                if let failure = model.failure { NativeFailureView(failure: failure, retry: { Task { await model.load() } }) }
                else { ProgressView() }
            }
            if let failure = model.failure, model.ready { NativeFailureView(failure: failure) }
            if session.pendingRestore != nil {
                HStack {
                    Text(EL("draftFound"))
                    Button(EL("restore")) { model.focus.handoff { confirmRestore = true } }
                    Button(EL("keepCurrent")) { session.keepCurrent() }
                    Button(EL("discard"), role: .destructive) { confirmDelete = true }
                }.padding()
            }
            if session.mode.showsTitle {
                MarkedTextEditor(buffer: titleBinding, focus: model.focus, isTitle: true, accessibilityLabel: EL("title"))
                    .frame(minHeight: 48, maxHeight: 90)
                metadata
            }
            if let quote = model.quotePrefix {
                HStack {
                    Text(quote).lineLimit(2)
                    Button(EL("removeQuote")) { model.removeQuote() }
                }.padding(.horizontal)
            }
            if model.previewing {
                ScrollView {
                    if let nodes = model.preview { EditorRichPreview(nodes: nodes).padding() }
                    else if model.failure == nil { ProgressView() }
                }
            } else {
                MarkedTextEditor(buffer: bodyBinding, focus: model.focus, accessibilityLabel: EL("body"))
                    .frame(minHeight: isMessage ? 100 : 180, maxHeight: isMessage ? 180 : .infinity)
            }
            if isMessage {
                Toggle(EL("markdown"), isOn: Binding(get: { session.markdown }, set: { session.markdown = $0; session.changed() })).padding(.horizontal)
                if model.acceptedResult != nil { Text(EL("acceptedMessage")).font(.caption).padding(.horizontal) }
            }
            if session.busy { ProgressView() }
            attachmentRows
            EditorToolbar(model: model, onPanel: { openPanel($0) }, onPhotos: {
                model.focus.handoff { showPhotos = true }
            })
        }
        .navigationTitle(EL(isMessage ? "messages" : (session.mode == .post ? "newPost" : "compose")))
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(!session.body.text.isEmpty || session.busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(EL("close")) { close() }.disabled(closing || session.busy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(EL(model.previewing ? "edit" : "preview")) {
                    model.focus.handoff {
                        if model.previewing { model.previewing = false }
                        else { Task { await model.showPreview() } }
                    }
                }
                Button(EL(isMessage ? "send" : "publish")) {
                    model.focus.handoff { confirmPublish = true }
                }.disabled(!model.ready || session.busy || session.pendingRestore != nil || session.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty || (!isMessage && session.accepted))
            }
        }
        .sheet(item: $sheet) { panel in
            NavigationStack { EditorPanelView(panel: panel, model: model).environmentObject(app) }
        }
        .sheet(isPresented: $showPhotos) {
            let pickerGeneration = app.generation
            EditorPhotoPicker(onFile: { url in
                guard pickerGeneration == app.generation else { try? FileManager.default.removeItem(at: url); return }
                model.addFile(url)
            }, onFailure: { if pickerGeneration == app.generation { model.failure = $0 } })
        }
        .confirmationDialog(EL("confirmPublish"), isPresented: $confirmPublish, titleVisibility: .visible) {
            Button(EL(isMessage ? "send" : "publish")) {
                model.focus.handoff { Task { await model.submit() } }
            }
        } message: { Text(EL("noAutoRetry")) }
        .confirmationDialog(EL("closeUnsaved"), isPresented: $confirmClose, titleVisibility: .visible) {
            Button(EL("close"), role: .destructive) { close(discardEdit: true) }
        }
        .confirmationDialog(EL("restoreConfirm"), isPresented: $confirmRestore, titleVisibility: .visible) {
            Button(EL("restore")) { if let value = session.pendingRestore { model.focus.handoff { session.restore(value) } } }
        }
        .confirmationDialog(EL("deleteDraftConfirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(EL("discard"), role: .destructive) { Task { do { try await session.deleteDraft() } catch { model.report(error) } } }
        }
        .alert(EL("accepted"), isPresented: Binding(get: { !isMessage && model.acceptedResult != nil }, set: { if !$0 { model.acceptedResult = nil } })) {
            Button(EL("viewResult")) { openAccepted() }
            Button(EL("keepDraft"), role: .cancel) { model.acceptedResult = nil }
        } message: { Text(EL("acceptedDetail")) }
        .task(id: app.generation) {
            if let generation, generation != app.generation { model.invalidate() }
            generation = app.generation
            MessageDraftMemory.align(app.generation)
            await model.load()
            if case .message(let uid) = session.mode, let draft = MessageDraftMemory.values[uid] { session.changeBody(draft.buffer); model.quotePrefix = draft.quote }
        }
        .task(id: app.generation) {
            if session.mode.showsTitle {
                await boards.load(app, "categories.get")
                await profile.load(app, "profile.self")
                await permissions.load(app, "editor.permissions", ["selfRank": profile.value["rank"] ?? .null])
                await recentBoards.load(app, "boards.recent.get")
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { model.focus.handoff { Task { do { try await model.flush() } catch { model.report(error) } } } }
        }
        .onDisappear {
            model.focus.handoff {
                guard generation == app.generation else { model.invalidate(); return }
                if case .message(let uid) = session.mode { MessageDraftMemory.values[uid] = .init(buffer: session.body, quote: model.quotePrefix) }
                Task { do { try await model.flush() } catch { model.report(error) } }
            }
        }
    }

    private var metadata: some View {
        VStack {
            if session.mode == .post {
                Menu {
                    let rows = boards.value.array ?? []
                    let recent = recentBoards.value.array?.compactMap(\.string) ?? []
                    Section(EL("recentBoards")) {
                        ForEach(recent, id: \.self) { slug in
                            if let row = rows.first(where: { $0["slug"]?.string == slug }) { boardButton(row) }
                        }
                    }
                    ForEach(rows.indices, id: \.self) { index in boardButton(rows[index]) }
                } label: { Label(session.boardTitle ?? EL("board"), systemImage: "folder") }
            }
            Menu {
                ForEach(permissions.value.array?.compactMap(\.int) ?? [], id: \.self) { rank in
                    Button(rank == 255 ? EL("private") : String(rank)) { session.permission = rank; session.changed() }
                }
            } label: { Label(session.permission == 255 ? EL("private") : "\(EL("permission")): \(session.permission)", systemImage: "lock") }
            if let failure = boards.failure { NativeFailureView(failure: failure, retry: { Task { await boards.load(app, "categories.refresh") } }) }
            if let failure = permissions.failure { NativeFailureView(failure: failure, retry: { Task { await permissions.load(app, "editor.permissions", ["selfRank": profile.value["rank"] ?? .null]) } }) }
        }.padding(.horizontal)
    }
    @ViewBuilder private func boardButton(_ row: JSONValue) -> some View {
        if let slug = row["slug"]?.string, let title = row["title"]?.string {
            Button(title) {
                session.boardSlug = slug; session.boardTitle = title; session.changed()
                Task {
                    do { recentBoards.value = try await app.request("boards.recent.record", ["categorySlug": .string(slug)]) }
                    catch { model.report(error) }
                }
            }
        }
    }
    private var attachmentRows: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(model.attachments) { item in
                    VStack {
                        Text(item.name).lineLimit(1)
                        Text(EL(item.phase.rawValue)).font(.caption)
                        if item.phase == .uploading { ProgressView() }
                        if item.phase == .waiting || item.phase == .failed {
                            Button(EL(item.phase == .failed ? "retryUpload" : "upload")) { model.upload(item.id) }
                        }
                        if let markdown = item.markdown {
                            Button(EL("insert")) { model.insert(markdown); model.removeAttachment(item.id) }
                        }
                        Button(EL("remove"), role: .destructive) { model.removeAttachment(item.id) }
                    }.frame(maxWidth: 160).padding(8)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func openPanel(_ panel: EditorPanel) { model.focus.handoff { sheet = panel } }
    private func close(discardEdit: Bool = false) {
        model.focus.handoff {
            if case .edit = session.mode, !session.accepted, !discardEdit { confirmClose = true; return }
            closing = true
            Task {
                defer { closing = false }
                do { try await model.flush(); dismiss() } catch { model.report(error) }
            }
        }
    }
    private func openAccepted() {
        let result = model.acceptedResult
        model.acceptedResult = nil
        switch session.mode {
        case .post:
            if let id = result?["postId"]?.int { app.open("PostDetail", ["postId": .integer(id)]) }
            else { dismiss() }
        case .reply(let id):
            var args: [String: JSONValue] = ["postId": .integer(id)]
            if let floor = result?["floor"]?.int { args["floor"] = .string(String(floor)) }
            app.open("PostDetail", args)
        case .edit(let id, _, let page, _): app.open("PostDetail", ["postId": .integer(id), "page": .integer(page)])
        case .message: break
        }
    }
}

@MainActor func editorRichActions(_ app: NativeAppModel, onVote: ((Int64) -> Void)? = nil) -> NativeRichTextActions {
    NativeRichTextActions(onImage: { url, _ in app.open("ImageViewer", ["url": .string(url)]) },
        onVote: onVote,
        onStardust: { receive in app.open("Stardust", ["memberId": .integer(receive.memberId), "refId": .integer(receive.refId), "amount": .integer(Int64(receive.amount)), "description": .string(receive.description), "onetime": .bool(receive.onetime)]) },
        onLink: { app.openLink($0) },
        onQuoteReference: { _, floor, url in app.openLink(url + (url.contains("#") ? "" : "#" + floor.trimmingCharacters(in: CharacterSet(charactersIn: "#")))) })
}
