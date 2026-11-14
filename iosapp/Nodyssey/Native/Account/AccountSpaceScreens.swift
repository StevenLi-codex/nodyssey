import SwiftUI
import NodysseyNativeCore

struct AccountFollowScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @State private var followers: Bool
    @State private var query = ""
    init(followers: Bool) { _followers = State(initialValue: followers) }
    private var operation: String { followers ? "social.followers" : "social.following" }
    var body: some View {
        List {
            if app.isSignedIn {
                Picker("follow_title", selection: $followers) {
                    Text("follow_tab_following").tag(false); Text("follow_tab_followers").tag(true)
                }.pickerStyle(.segmented)
                AccountStoreStatus(store: store) { Task { await store.load(app, operation) } }
                let rows = AccountUserRow.rows(store.value, query: query)
                if rows.isEmpty && !store.isLoading && store.failure == nil {
                    Text(LocalizedStringKey(followers ? "follow_empty_followers_title" : "follow_empty_following_title"))
                }
                ForEach(rows) { row in
                    Button { app.open("UserSpace", ["uid": .integer(row.id)]) } label: {
                        HStack {
                            if let url = row.avatar { NativeRemoteImage(url: url).frame(width: 40, height: 40).clipShape(Circle()) }
                            Text(row.name)
                        }
                    }
                }
            } else { AccountRequireSignIn() }
        }
        .navigationTitle("follow_title")
        .searchable(text: $query, prompt: "search_user_hint")
        .task(id: operation + String(app.generation)) { store.invalidate(); await store.load(app, operation) }
        .refreshable { await store.load(app, operation) }
    }
}

struct AccountOwnPostsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var profile = NativeStore()
    let comments: Bool
    var body: some View {
        Group {
            if !app.isSignedIn { Form { AccountRequireSignIn() } }
            else if let uid = profile.value.nativeInt("uid") {
                AccountPostPage(uid: uid, mode: comments ? "comments" : "topics").id("\(uid):\(app.generation)")
            } else {
                AccountStoreStatus(store: profile) { Task { await profile.load(app, "profile.self", ["refresh": .bool(true)]) } }
            }
        }
        .navigationTitle(LocalizedStringKey(comments ? "profile_tile_comments" : "profile_tile_topics"))
        .task(id: app.generation) { await profile.observe(app, "profile.self") }
    }
}

struct AccountSpaceScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let uid: Int64
    let requestedCollections: Bool
    @StateObject private var profile = NativeStore()
    @StateObject private var own = NativeStore()
    @StateObject private var notes = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var tab = "general"
    @State private var note = ""
    @State private var pending: AccountPendingWrite?
    @State private var noteLoaded = false
    private var isSelf: Bool { own.value.nativeInt("uid") == uid && app.isSignedIn }

    var body: some View {
        VStack {
            Picker("space_tab_general", selection: $tab) {
                Text("space_tab_general").tag("general")
                Text("space_tab_topics").tag("topics")
                Text("space_tab_comments").tag("comments")
                if isSelf { Text("space_tab_collections").tag("collections") }
            }.pickerStyle(.segmented).padding(.horizontal)
            if tab == "general" {
                List {
                    AccountStoreStatus(store: profile) { reload() }
                    if profile.value != .null {
                        AccountProfileHeader(profile: profile.value)
                        if let topics = profile.value.nativeInt("topicCount") { LabeledContent("space_stat_topics", value: String(topics)) }
                        if let comments = profile.value.nativeInt("commentCount") { LabeledContent("space_stat_comments", value: String(comments)) }
                        if isSelf { Button("profile_edit") { app.open("AccountProfileFields") } }
                        else {
                            Button(LocalizedStringKey(profile.value.nativeBool("followed") == true ? "space_following" : "space_follow")) {
                                guard app.isSignedIn else { app.showSignIn(); return }
                                pending = AccountPendingWrite(profile.value.nativeBool("followed") == true ? "social.unfollow" : "social.follow", ["uid": .integer(uid)])
                            }.disabled(action.blocked)
                            Button("space_message") {
                                guard app.isSignedIn else { app.showSignIn(); return }
                                if let name = profile.value.nativeString("name") { app.open("MessageThread", ["uid": .integer(uid), "userName": .string(name)]) }
                            }
                        }
                        Section {
                            AccountStoreStatus(store: notes) { Task { await loadNotes() } }
                            TextField(String(localized: "native.account.note", table: "Account"), text: $note, axis: .vertical)
                            Button("account_action_save") { pending = AccountPendingWrite("notes.set", ["uid": .integer(uid), "note": .string(note)]) }
                                .disabled(action.blocked || !noteLoaded)
                        }
                        if let readme = profile.value.nativeString("readme"), !readme.isEmpty {
                            Section("space_readme") { AccountMarkdown(bodyText: readme) }
                        }
                    }
                    AccountActionStatus(action: action)
                }.refreshable { await profile.load(app, "profile.user", ["uid": .integer(uid)]) }
            } else {
                AccountPostPage(uid: uid, mode: tab).id("\(uid):\(tab):\(app.generation)")
            }
        }
        .navigationTitle(profile.value.nativeString("name") ?? String(localized: "space_tab_general"))
        .task(id: app.generation) {
            action.cancel(); pending = nil; note = ""; noteLoaded = false; tab = "general"
            await own.load(app, "profile.self")
            if requestedCollections && isSelf { tab = "collections" }
            await profile.load(app, "profile.user", ["uid": .integer(uid)])
            await loadNotes()
        }
        .confirmationDialog("account_action_save", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("action_done") {
                guard let write = pending else { return }; pending = nil
                action.perform(app, operation: write.operation, arguments: write.arguments, read: {
                    if write.operation == "notes.set" {
                        notes.value = try await app.request("notes.get"); applyNote()
                    } else { profile.value = try await app.request("profile.user", ["uid": .integer(uid)]) }
                })
            }
        }
        .onDisappear { action.cancel() }
    }
    private func reload() { Task { await profile.load(app, "profile.user", ["uid": .integer(uid)]) } }
    private func applyNote() {
        note = (notes.value.array ?? []).first { $0.nativeInt("uid") == uid }?.nativeString("note") ?? ""
        noteLoaded = true
    }
    private func loadNotes() async { await notes.load(app, "notes.get"); if notes.failure == nil { applyNote() } }
}

struct AccountPostPage: View {
    @EnvironmentObject private var app: NativeAppModel
    let uid: Int64
    let mode: String
    @State private var page = AccountPageState()
    @State private var requested: Int64 = 1
    @State private var jump = ""
    @State private var query = ""
    @State private var board = ""
    @State private var newestFirst = true
    @State private var loading = false
    @State private var failure: NativeFailure?
    @State private var refresh = 0
    private var operation: String { mode == "collections" ? "space.collections" : mode == "comments" ? "space.comments" : "space.topics" }
    var body: some View {
        List {
            Section {
                Text("native.account.page_filter", tableName: "Account").font(.caption)
                if mode != "comments" {
                    Picker("search_board_section", selection: $board) {
                        Text("search_all_boards").tag("")
                        ForEach(Array(Set(page.items.compactMap { $0.nativeString("categorySlug") })).sorted(), id: \.self) { slug in Text(slug).tag(slug) }
                    }
                }
                Toggle(String(localized: "native.account.server_order", table: "Account"), isOn: $newestFirst)
            }
            if loading { ProgressView() }
            if let failure { NativeFailureView(failure: failure, retry: { refresh += 1 }) }
            let rows = visibleRows
            if rows.isEmpty && !loading && failure == nil { Text(LocalizedStringKey(mode == "comments" ? "space_empty_comments" : mode == "collections" ? "space_empty_collections" : "space_empty_topics")) }
            ForEach(rows) { row in
                Button { open(row.value) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.value.nativeString("title") ?? row.value.nativeString("postTitle") ?? "#\(String(row.value.nativeInt("postId")!))")
                        if let excerpt = row.value.nativeString("excerpt") { Text(excerpt).font(.callout).foregroundStyle(.secondary) }
                        HStack {
                            if let board = row.value.nativeString("categoryTitle") { Text(board) }
                            if let date = row.value.nativeString("createdAtText") { Text(date) }
                            if let count = row.value.nativeInt("commentCount") { Label(String(count), systemImage: "bubble") }
                        }.font(.caption)
                    }
                }
            }
            Section {
                HStack {
                    Button { requested = max(1, page.page - 1) } label: { Image(systemName: "chevron.left").accessibilityLabel(Text("action_back")) }.disabled(page.page <= 1 || loading)
                    Spacer(); Text(String(page.page)); Spacer()
                    Button { requested = page.page + 1 } label: { Image(systemName: "chevron.right").accessibilityLabel(Text("action_more")) }.disabled(!page.hasNext || loading)
                }
                HStack {
                    TextField(String(localized: "native.account.page", table: "Account"), text: $jump).keyboardType(.numberPad)
                    Button("action_done") { if let value = Int64(jump), value > 0 { requested = value; refresh += 1 } }.disabled(Int64(jump).map { $0 <= 0 } ?? true)
                }
            }
        }
        .searchable(text: $query)
        .task(id: "\(uid):\(mode):\(requested):\(refresh):\(app.generation)") { await load() }
        .refreshable { refresh += 1 }
        .onChange(of: app.generation) { _ in page.invalidate(); requested = 1; query = ""; board = "" }
        .onDisappear { page.invalidate() }
    }
    private var visibleRows: [AccountPostRow] {
        var seen = Set<String>()
        return page.filtered(query: query, board: board, newestFirst: newestFirst).compactMap { value in
            let id = "\(value.nativeInt("postId")!):\(value.nativeInt("commentId").map(String.init) ?? ""):\(value["floor"].map { String(describing: $0) } ?? ""):\(value.nativeString("excerpt") ?? "")"
            return seen.insert(id).inserted ? AccountPostRow(id: id, value: value) : nil
        }
    }
    private func load() async {
        loading = true; failure = nil
        let ticket = page.begin(page: requested)
        var args: [String: JSONValue] = ["page": .integer(requested)]
        if mode != "collections" { args["uid"] = .integer(uid) }
        do {
            let result = try await app.request(operation, args)
            try Task.checkCancellation()
            try page.accept(result, ticket: ticket); loading = false
        } catch { if !Task.isCancelled { failure = accountFailure(error); loading = false } }
    }
    private func open(_ value: JSONValue) {
        guard let id = value.nativeInt("postId") else { return }
        var args: [String: JSONValue] = ["postId": .integer(id)]
        if let floor = value["floor"], floor != .null { args["floor"] = floor }
        app.open("PostDetail", args)
    }
}

struct AccountPostRow: Identifiable { let id: String; let value: JSONValue }
