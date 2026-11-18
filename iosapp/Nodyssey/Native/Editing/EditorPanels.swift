import SwiftUI
import NodysseyNativeCore

enum EditorPanel: String, Identifiable { case stickers, link, mention, vote, receive, hosted, toolbar; var id: String { rawValue } }

struct EditorToolbar: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var model: EditorViewModel
    let onPanel: (EditorPanel) -> Void
    let onPhotos: () -> Void
    var compact = false
    static let all = EditorToolbarLayout.all
    static func defaults(_ surface: String) -> [String] { EditorToolbarLayout.defaults(surface) }
    private var actions: [String] {
        let key = model.session.mode.surface.lowercased() + "ToolbarActions"
        return EditorToolbarLayout.actions(app.settings[key]?.array?.compactMap(\.string), surface: model.session.mode.surface)
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(actions, id: \.self) { action in
                    Button { perform(action) } label: {
                        if compact { Image(systemName: symbol(action)).frame(minWidth: 44, minHeight: 44).accessibilityLabel(EL(action)) }
                        else { Text(EL(action)) }
                    }
                }
                if compact {
                    Menu {
                        Button(EL("vote")) { onPanel(.vote) }
                        Button(EL("receive")) { onPanel(.receive) }
                        Button(EL("toolbar")) { onPanel(.toolbar) }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                } else {
                    if model.session.mode.surface != "MESSAGE" {
                        Button(EL("vote")) { onPanel(.vote) }
                        Button(EL("receive")) { onPanel(.receive) }
                    }
                    Button { onPanel(.toolbar) } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel(EL("toolbar"))
                }
            }.padding(10)
        }.disabled(model.session.busy || !model.ready)
    }
    private func symbol(_ action: String) -> String {
        switch action {
        case "IMAGE": return "photo"
        case "HOSTED_IMAGE": return "photo.on.rectangle"
        case "EMOJI": return "face.smiling"
        case "MENTION": return "at"
        case "BOLD": return "bold"
        case "LINK": return "link"
        case "QUOTE": return "text.quote"
        case "CODE": return "chevron.left.forwardslash.chevron.right"
        case "LIST": return "list.bullet"
        case "HEADING": return "textformat.size"
        case "STRIKETHROUGH": return "strikethrough"
        default: return "italic"
        }
    }
    private func perform(_ action: String) {
        switch action {
        case "IMAGE": onPhotos()
        case "HOSTED_IMAGE": onPanel(.hosted)
        case "EMOJI": onPanel(.stickers)
        case "MENTION": onPanel(.mention)
        case "LINK": onPanel(.link)
        case "BOLD": model.wrap("**", "**")
        case "ITALIC": model.wrap("*", "*")
        case "STRIKETHROUGH": model.wrap("~~", "~~")
        case "CODE": model.wrap("\n```\n", "\n```\n")
        case "QUOTE": model.wrap("\n> ", "\n")
        case "LIST": model.wrap("\n- ", "\n")
        case "HEADING": model.wrap("\n## ", "\n")
        default: break
        }
    }
}

struct EditorPanelView: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let panel: EditorPanel
    @ObservedObject var model: EditorViewModel
    var embedded = false
    @StateObject private var store = NativeStore()
    @State private var text = ""
    @State private var url = ""
    @State private var options = ""
    @State private var multiple = false
    @State private var isPublic = true
    @State private var amount = "1"
    @State private var reference = String(Int64.random(in: 100...100_000_099))
    @State private var onetime = true
    @State private var busy = false
    @State private var confirmVote = false
    @State private var toolbar: [String] = []
    @State private var loadID = 0
    @State private var voteMutation = NativeMutationState()
    @State private var createdVoteID: Int64?

    var body: some View {
        Group {
            switch panel {
            case .stickers: NativeStickerPicker(onSelect: insert)
            case .hosted: hostedList
            case .toolbar: toolbarList
            default: inputForm
            }
        }
        .navigationTitle(EL(panel.rawValue))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(EL("close")) { dismiss() }.disabled(busy) } }
        .interactiveDismissDisabled(busy)
        .task(id: "\(app.generation):\(loadID)") {
            switch panel {
            case .hosted: await store.load(app, "imageHost.images")
            case .receive: await store.load(app, "profile.self")
            case .toolbar:
                let key = model.session.mode.surface.lowercased() + "ToolbarActions"
                toolbar = EditorToolbarLayout.actions(app.settings[key]?.array?.compactMap(\.string), surface: model.session.mode.surface)
            default: break
            }
        }
        .confirmationDialog(EL("createVoteConfirm"), isPresented: $confirmVote, titleVisibility: .visible) {
            Button(EL("createVote")) { createVote() }
        } message: { Text(EL("noAutoRetry")) }
        .onChange(of: app.generation) { _ in voteMutation.invalidate(); dismiss() }
    }

    private var inputForm: some View {
        Form {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { loadID += 1 }) }
            if let failure = model.failure { NativeFailureView(failure: failure) }
            if busy || store.isLoading { ProgressView() }
            switch panel {
            case .link:
                TextField(EL("label"), text: $text)
                TextField(EL("url"), text: $url).autocorrectionDisabled()
                Button(EL("insert")) {
                    guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil, parsed.user == nil else { return }
                    insert("[\(escapeLabel(text))](\(escapeURL(url)))")
                }.disabled(URL(string: url)?.host == nil)
            case .mention:
                TextField(EL("userName"), text: $text)
                Button(EL("search")) { Task { await store.load(app, "search.users", ["query": .string(text)]) } }.disabled(text.isEmpty)
                ForEach(Array((store.value.array ?? []).enumerated()), id: \.offset) { _, user in
                    if let name = user["name"]?.string, user["uid"]?.int != nil { Button(name) { insert("@\(name) ") } }
                }
            case .vote:
                TextField(EL("title"), text: $text)
                TextEditor(text: $options).frame(minHeight: 120).accessibilityLabel(EL("voteOptions"))
                Text(EL("voteOptions")).font(.caption)
                Toggle(EL("multiple"), isOn: $multiple)
                Toggle(EL("publicVote"), isOn: $isPublic)
                Button(EL("createVote")) { confirmVote = true }.disabled(busy || createdVoteID != nil || text.isEmpty || voteItems.count < 2)
                if let id = createdVoteID {
                    Button(EL("refresh")) { Task { await verifyCreatedVote(id) } }.disabled(busy)
                }
            case .receive:
                TextField(EL("amount"), text: $amount)
                TextField(EL("reference"), text: $reference)
                TextField(EL("description"), text: $text)
                Toggle(EL("onetime"), isOn: $onetime)
                if let uid = store.value["uid"]?.int, uid > 0 {
                    Text("\(EL("payee")): \(store.value["name"]?.string ?? String(uid))")
                    Button(EL("insert")) {
                        guard let amount = Int64(amount), amount > 0, amount <= Int64(Int32.max), let reference = Int64(reference), reference >= 0 else { return }
                        insert(EditorMarkup.receive(member: uid, reference: reference, amount: amount, description: text.isEmpty ? "Pay with Stardust" : text, onetime: onetime))
                    }.disabled((Int64(amount) ?? 0) <= 0 || Int64(reference) == nil)
                } else { Text(EL("payeeUnavailable")) }
            default: EmptyView()
            }
        }
    }
    private var voteItems: [String] { options.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private func createVote() {
        guard !busy, createdVoteID == nil else { return }
        busy = true
        let generation = app.generation
        // Only a confirmed create action contacts the server. No retry on transport ambiguity.
        Task {
            defer { busy = false }
            do {
                voteMutation.draft = text
                let result = try await voteMutation.submit(using: app.transport, operation: "vote.create", arguments: ["multiple": .bool(multiple), "isPublic": .bool(isPublic), "items": .array(voteItems.map(JSONValue.string))], draftKey: "title")
                guard generation == app.generation else { return }
                guard let id = result["id"]?.int, id > 0 else { throw NativeFailure(code: "INVALID_DATA", message: "Missing vote identity") }
                createdVoteID = id
                await verifyCreatedVote(id)
            } catch { model.report(error) }
        }
    }
    private func verifyCreatedVote(_ id: Int64) async {
        busy = true
        defer { busy = false }
        do {
            let vote = try await app.request("vote.get", ["voteId": .integer(id)])
            guard vote["id"]?.int == id else { throw NativeFailure(code: "INVALID_DATA", message: "Vote read-back failed") }
            insert(" nsapp://vote?id=\(id) ")
        } catch { model.report(error) }
    }
    private var hostedList: some View {
        List {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { loadID += 1 }) }
            if store.isLoading { ProgressView() }
            ForEach(Array((store.value.array ?? []).enumerated()), id: \.offset) { _, image in
                if let url = image["url"]?.string {
                    HStack {
                        NativeRemoteImage(url: url).frame(width: 60, height: 60)
                        Button(image["fileName"]?.string ?? EL("insert")) { insert("![\(escapeLabel(image["fileName"]?.string ?? ""))](\(escapeURL(url)))") }
                    }
                }
            }
            Button(EL("imageHost")) { dismiss(); app.open("ImageHost") }
        }
    }
    private var toolbarList: some View {
        List {
            Section(EL("visible")) {
                ForEach(toolbar, id: \.self) { key in
                    Text(EL(key)).deleteDisabled(toolbar.count <= 1)
                }
                    .onMove { source, target in toolbar.move(fromOffsets: source, toOffset: target) }
                    .onDelete { toolbar = EditorToolbarLayout.removing($0, from: toolbar) }
            }
            Section(EL("available")) {
                ForEach(EditorToolbar.all.filter { !toolbar.contains($0) }, id: \.self) { key in
                    Button(EL(key)) { toolbar.append(key) }
                }
            }
            Button(EL("reset")) { toolbar = EditorToolbar.defaults(model.session.mode.surface) }
            Button(EL("save")) {
                guard !busy, !toolbar.isEmpty else { return }
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        app.settings = try await app.request("settings.toolbar", ["surface": .string(model.session.mode.surface), "actions": .array(toolbar.map(JSONValue.string))])
                        dismiss()
                    } catch { model.report(error) }
                }
            }.disabled(busy || toolbar.isEmpty)
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
    }
    private func insert(_ value: String) { model.insert(value); if !embedded { dismiss() } }
    private func escapeLabel(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ") }
    private func escapeURL(_ value: String) -> String { value.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20") }
}
