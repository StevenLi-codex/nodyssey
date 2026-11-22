import SwiftUI
import NodysseyNativeCore

/// Same production registration is exercised by Foundation's route tests.
/// No normal-save path is used by identity revocation.
@MainActor final class NativeEditorRouteLifetime: ObservableObject {
    let model: EditorViewModel
    @Published var needsDraftDecision = false
    @Published var needsDiscardDecision = false
    @Published private(set) var closing = false
    private weak var app: NativeAppModel?
    private var destinationID: UUID?
    private var token: UUID?
    private var decision: EditorViewModel.CloseDecision?

    init(model: EditorViewModel) { self.model = model }
    func register(app: NativeAppModel, destinationID: UUID) {
        guard token == nil, !model.isClosed else { return }
        self.app = app
        self.destinationID = destinationID
        token = app.registerDismissal(destinationID: destinationID, close: { [self] in
            await closeForNavigation()
        }, revoke: { [self] in model.invalidate() }, terminate: { [self] in
            model.terminateAfterPrepared()
        }, validate: { [self] in
            model.isDeparturePreparationValid
        })
    }

    func dismiss(decision: EditorViewModel.CloseDecision? = nil) async {
        self.decision = decision
        defer { self.decision = nil }
        guard let app, let destinationID else { return }
        await app.dismissDestination(destinationID)
    }

    private func closeForNavigation() async -> Bool {
        guard !closing else { return false }
        if model.isClosed { return true }
        model.focus.handoff {}
        if decision == nil, case .edit = model.session.mode, !model.session.accepted {
            needsDiscardDecision = true
            return false
        }
        if decision == nil, model.session.pendingRestore != nil {
            needsDraftDecision = true
            return false
        }
        closing = true
        defer { closing = false }
        do { try await model.prepareForDeparture(decision: decision); return true }
        catch { model.report(error); return false }
    }
}

#if !FOUNDATION_EDITOR_TESTS
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

private struct EditorHost: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.nativeDestinationID) private var destinationID
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: EditorViewModel
    @StateObject private var routeLifetime: NativeEditorRouteLifetime
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

    let arguments: [String: JSONValue]

    init(mode: EditorMode, arguments: [String: JSONValue], transport: any NativeTransport) {
        let model = EditorViewModel(mode: mode, transport: transport, arguments: arguments)
        _model = StateObject(wrappedValue: model)
        _routeLifetime = StateObject(wrappedValue: NativeEditorRouteLifetime(model: model))
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
    private var submitTitle: String {
        if case .edit = session.mode { return EL("save") }
        return EL(isMessage ? "send" : "publishReply")
    }
    private var permissionTitle: String {
        if session.permission == 0 { return PCL("permissionPublic") }
        if session.permission == 255 { return EL("private") }
        return "\(EL("permission")): \(session.permission)"
    }

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
                    Spacer()
                    Button(EL("restore")) { model.focus.handoff { confirmRestore = true } }
                    Menu {
                        Button(EL("keepCurrent")) { model.focus.handoff { session.keepCurrent() } }
                        Button(EL("discard"), role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(PCL("draftOptions"))
                }.font(.subheadline).padding(.horizontal, 16)
            }
            if session.mode.showsTitle {
                // Original ComposerOptions precedes its borderless page heading.
                // Keep metadata shallow rather than turning the editor into cards.
                metadata
                    .padding(.vertical, 8)
                    .background(.quaternary)
                NativeComposerField(buffer: titleBinding, focus: model.focus, isTitle: true,
                                    accessibilityLabel: EL("title"), hint: PCL("titleHint"))
                    .frame(minHeight: 48, maxHeight: 90)
                    .padding(.horizontal, 7)
                    .padding(.top, 12)
                Divider().padding(.horizontal, 16)
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
                NativeComposerField(buffer: bodyBinding, focus: model.focus, accessibilityLabel: EL("body"),
                                    hint: session.mode.showsTitle ? PCL("bodyHint") : EL("body"))
                    .frame(minHeight: isMessage ? 48 : 80, maxHeight: isMessage ? 120 : .infinity)
                    .padding(.horizontal, 7)
                    .padding(.top, 8)
                    // A conversation answers in a single field, not a page body:
                    // keep every control, give the input its own rounded surface.
                    .modifier(MessageInputSurface(enabled: isMessage))
            }
            if isMessage {
                Toggle(EL("markdown"), isOn: Binding(get: { session.markdown }, set: { session.markdown = $0; session.changed() })).padding(.horizontal)
                if model.acceptedResult != nil { Text(EL("acceptedMessage")).font(.caption).padding(.horizontal) }
            }
            attachmentRows
            EditorToolbar(model: model, onPanel: { openPanel($0) }, onPhotos: {
                model.focus.handoff { showPhotos = true }
            }, compact: !isMessage)
        }
        .disabled(routeLifetime.closing || app.departureRunning)
        .navigationTitle(EL(isMessage ? "messages" : (session.mode == .post ? "newPost" : "compose")))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationBarBackButtonHidden(true)
        // All permanent exits must run the awaited close/teardown path, even
        // for title-only drafts or attachments with an empty body.
        .interactiveDismissDisabled(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { close() } label: {
                    Label(EL("close"), systemImage: "xmark")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }.disabled(routeLifetime.closing || session.busy)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.focus.handoff {
                        if model.previewing { model.previewing = false }
                        else { Task { await model.showPreview() } }
                    }
                } label: {
                    Label(EL(model.previewing ? "edit" : "preview"), systemImage: model.previewing ? "pencil" : "eye")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                Button {
                    model.focus.handoff { confirmPublish = true }
                } label: {
                    HStack(spacing: 6) {
                        if session.busy { ProgressView().controlSize(.small) }
                        Text(submitTitle)
                    }.frame(minHeight: 44)
                }.disabled(!model.ready || session.busy || session.pendingRestore != nil || session.body.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty || (!isMessage && session.accepted))
            }
        }
        .sheet(item: $sheet) { panel in
            NavigationStack { EditorPanelView(panel: panel, model: model).environmentObject(app) }
        }
        .sheet(isPresented: $showPhotos) {
            EditorPhotoPicker(model: model)
        }
        .confirmationDialog(EL("confirmPublish"), isPresented: $confirmPublish, titleVisibility: .visible) {
            Button(submitTitle) {
                model.focus.handoff { Task { await model.submit() } }
            }
        } message: { Text(EL("noAutoRetry")) }
        .confirmationDialog(EL("closeUnsaved"), isPresented: $routeLifetime.needsDiscardDecision, titleVisibility: .visible) {
            Button(EL("close"), role: .destructive) { close(decision: .discardCurrent) }
        }
        .confirmationDialog(EL("closeDraftDecision"), isPresented: $routeLifetime.needsDraftDecision, titleVisibility: .visible) {
            Button(EL("restoreAndClose")) { close(decision: .restore) }
            Button(EL("keepCurrentAndClose")) { close(decision: .keepCurrent) }
            Button(EL("discardCurrentAndClose"), role: .destructive) { close(decision: .discardCurrent) }
        } message: { Text(EL("closeDraftDecisionDetail")) }
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
            if let destinationID { routeLifetime.register(app: app, destinationID: destinationID) }
            if let generation, generation != app.generation { model.invalidate() }
            generation = app.generation
            await model.appear(generation: app.generation)
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
                guard !model.isClosed else { return }
                guard generation == app.generation else { model.invalidate(); return }
                model.cacheMessage()
                Task { do { try await model.flush() } catch { model.report(error) } }
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
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
                            Button(rank == 0 ? PCL("permissionPublic") : rank == 255 ? EL("private") : String(rank)) { session.permission = rank; session.changed() }
                        }
                    } label: {
                        Label(permissionTitle,
                              systemImage: session.permission == 0 ? "globe" : "lock")
                    }.accessibilityLabel(EL("permission")).accessibilityValue(permissionTitle)
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }
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
    private func close(decision: EditorViewModel.CloseDecision? = nil) {
        Task { await routeLifetime.dismiss(decision: decision) }
    }
    private func openAccepted() {
        model.focus.handoff {
            let result = model.acceptedResult
            model.acceptedResult = nil
            // app.open pushes a destination; that disappearance is temporary.
            // Only the no-identity dismissal below permanently closes this editor.
            switch session.mode {
            case .post:
                if let id = result?["postId"]?.int { app.open("PostDetail", ["postId": .integer(id)]) }
                else { close() }
            case .reply(let id):
                var args: [String: JSONValue] = ["postId": .integer(id)]
                if let floor = result?["floor"]?.int { args["floor"] = .string(String(floor)) }
                app.open("PostDetail", args)
            case .edit(let id, _, let page, _): app.open("PostDetail", ["postId": .integer(id), "page": .integer(page)])
            case .message: break
            }
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
#endif

private struct MessageInputSurface: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content.background {
            if enabled { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary) }
        }
    }
}
