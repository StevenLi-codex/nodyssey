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
                    if query.isEmpty { Text(LocalizedStringKey(followers ? "follow_empty_followers_title" : "follow_empty_following_title")) }
                    else { Text("native.account.no_matches", tableName: "Account") }
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
        .nativeRefreshable(generation: app.generation, failure: { store.failure != nil }) { await store.load(app, operation) }
    }
}

struct AccountOwnPostsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var profile = AccountSelfProfileState()
    let comments: Bool
    var body: some View {
        Group {
            if !app.isSignedIn { Form { AccountRequireSignIn() } }
            else if let uid = profile.value.nativeInt("uid") {
                AccountPostPage(uid: uid, mode: comments ? "comments" : "topics").id("\(uid):\(app.generation)")
            } else {
                AccountProfileStatus(profile: profile)
            }
        }
        .navigationTitle(LocalizedStringKey(comments ? "profile_tile_comments" : "profile_tile_topics"))
        .task(id: app.generation) {
            if app.isSignedIn { await profile.run(using: app.transport, currentGeneration: { app.generation }) }
            else { profile.invalidate() }
        }
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
    @State private var readmeExpanded = false
    private var isSelf: Bool { own.value.nativeInt("uid") == uid && app.isSignedIn }

    var body: some View {
        VStack(spacing: 0) {
            if profile.value != .null {
                AccountProfileHeader(profile: profile.value).padding(.horizontal, 16)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 24) {
                    spaceTab("space_tab_general", value: "general")
                    spaceTab("space_tab_topics", value: "topics")
                    spaceTab("space_tab_comments", value: "comments")
                    if isSelf { spaceTab("space_tab_collections", value: "collections") }
                }.padding(.horizontal, 16)
            }.background(AccountSurface())
            Divider()
            if tab == "general" {
                List {
                    AccountStoreStatus(store: profile) { reload() }
                    if profile.value != .null {
                        HStack(spacing: 36) {
                            if let topics = profile.value.nativeInt("topicCount") { AccountProfileStat(title: "space_stat_topics", value: topics) }
                            if let comments = profile.value.nativeInt("commentCount") { AccountProfileStat(title: "space_stat_comments", value: comments) }
                        }.padding(.vertical, 8)
                        if isSelf {
                            Button("profile_edit") { app.open("AccountProfileFields") }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                        } else {
                          ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { socialActions }
                            VStack(alignment: .leading, spacing: 8) { socialActions }
                          }
                        }
                        if !isSelf && app.isSignedIn { DisclosureGroup {
                            AccountStoreStatus(store: notes) { Task { await loadNotes() } }
                            TextField(String(localized: "native.account.note", table: "Account"), text: $note, axis: .vertical)
                            Button("account_action_save") { pending = AccountPendingWrite("notes.set", ["uid": .integer(uid), "note": .string(note)]) }
                                .disabled(action.blocked || !noteLoaded)
                        } label: { Text("native.account.note", tableName: "Account") } }
                        Section("space_readme") {
                            if let readme = profile.value.nativeString("readme"), !readme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                if readme.components(separatedBy: .newlines).count > 8 {
                                    DisclosureGroup(isExpanded: $readmeExpanded) { AccountMarkdown(bodyText: readme) } label: {
                                        Text(LocalizedStringKey(readmeExpanded ? "space_readme_collapse" : "space_readme_expand"))
                                    }
                                } else { AccountMarkdown(bodyText: readme) }
                            } else { Text("space_readme_empty").foregroundStyle(.secondary) }
                        }
                    }
                    AccountActionStatus(action: action)
                }
                .listStyle(.plain).scrollContentBackground(.hidden).background(AccountSurface(canvas: true))
                .nativeRefreshable(generation: app.generation, failure: { profile.failure != nil }) { await profile.load(app, "profile.user", ["uid": .integer(uid)]) }
            } else {
                AccountPostPage(uid: uid, mode: tab).id("\(uid):\(tab):\(app.generation)")
            }
        }
        .nativePageCanvas()
        .navigationTitle(profile.value.nativeString("name") ?? String(localized: "space_tab_general"))
        .toolbar {
            Menu {
                if let origin = app.siteOrigin {
                    Button("action_open_in_browser") {
                        app.open("Web", ["url": .string(origin + "/space/" + String(uid)), "goal": .string("EXTERNAL"), "title": .string(profile.value.nativeString("name") ?? String(uid))])
                    }
                }
            } label: { Image(systemName: "ellipsis").accessibilityLabel(Text("action_more")) }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: app.generation) {
            action.cancel(); pending = nil; note = ""; noteLoaded = false; tab = "general"
            if app.isSignedIn { await own.load(app, "profile.self") }
            else { own.invalidate() }
            if requestedCollections && isSelf { tab = "collections" }
            await profile.load(app, "profile.user", ["uid": .integer(uid)])
            if app.isSignedIn && !isSelf { await loadNotes() }
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
    private func spaceTab(_ title: LocalizedStringKey, value: String) -> some View {
        Button { tab = value } label: {
            Text(title).font(.subheadline.weight(tab == value ? .semibold : .regular))
                .foregroundStyle(tab == value ? Color.primary : Color.secondary)
                .frame(minWidth: 44, minHeight: 48)
                .overlay(alignment: .bottom) {
                    if tab == value { Capsule().fill(.tint).frame(width: 22, height: 3) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? [.isSelected] : [])
    }
    private var socialActions: some View {
        Group {
            Button(LocalizedStringKey(profile.value.nativeBool("followed") == true ? "space_following" : "space_follow")) {
                guard app.isSignedIn else { app.showSignIn(); return }
                pending = AccountPendingWrite(profile.value.nativeBool("followed") == true ? "social.unfollow" : "social.follow", ["uid": .integer(uid)])
            }.buttonStyle(.borderedProminent).disabled(action.blocked).frame(minHeight: 44)
            Button("space_message") {
                guard app.isSignedIn else { app.showSignIn(); return }
                if let name = profile.value.nativeString("name") { app.open("MessageThread", ["uid": .integer(uid), "userName": .string(name)]) }
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }
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
    private var loading: Bool { readFlight.isLoading }
    @State private var failure: NativeFailure?
    @StateObject private var readFlight = AccountReadFlightState()
    @State private var refreshSucceeded = false
    private var requestKey: String { "\(uid):\(mode):\(requested):\(app.generation)" }
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
            if let failure { NativeFailureView(failure: failure, retry: { Task { await load() } }) }
            let rows = visibleRows
            if rows.isEmpty && !loading && failure == nil {
                if !query.isEmpty || !board.isEmpty { Text("native.account.no_matches", tableName: "Account") }
                else { Text(LocalizedStringKey(mode == "comments" ? "space_empty_comments" : mode == "collections" ? "space_empty_collections" : "space_empty_topics")) }
            }
            ForEach(rows) { row in
                Button { open(row.value) } label: {
                    AccountSpacePostCard(value: row.value)
                }.buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden).listRowBackground(AccountSurface(canvas: true))
            }
            Section {
                HStack {
                    Button { requested = max(1, page.page - 1) } label: { Image(systemName: "chevron.left").accessibilityLabel(Text("action_back")) }.disabled(page.page <= 1 || loading)
                    Spacer(); Text(String(page.page)); Spacer()
                    Button { requested = page.page + 1 } label: { Image(systemName: "chevron.right").accessibilityLabel(Text("action_more")) }.disabled(!page.hasNext || loading)
                }
                HStack {
                    TextField(String(localized: "native.account.page", table: "Account"), text: $jump).keyboardType(.numberPad)
                    Button("action_done") { if let value = Int64(jump), value > 0 { if requested == value { Task { await load() } } else { requested = value } } }.disabled(Int64(jump).map { $0 <= 0 } ?? true)
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).nativePageCanvas()
        .searchable(text: $query)
        .task(id: requestKey) { await load() }
        .nativeRefreshable(generation: app.generation, failure: { failure != nil }, completion: { refreshSucceeded }) {
            refreshSucceeded = false
            refreshSucceeded = await load()
        }
        .onChange(of: app.generation) { _ in readFlight.cancel(); failure = nil; page.invalidate(); requested = 1; query = ""; board = "" }
        .onDisappear { readFlight.cancel(); page.suspend() }
    }
    private var visibleRows: [AccountPostRow] {
        var seen = Set<String>()
        return page.filtered(query: query, board: board, newestFirst: newestFirst).compactMap { value in
            let id = "\(value.nativeInt("postId")!):\(value.nativeInt("commentId").map(String.init) ?? ""):\(value["floor"].map { String(describing: $0) } ?? ""):\(value.nativeString("excerpt") ?? "")"
            return seen.insert(id).inserted ? AccountPostRow(id: id, value: value) : nil
        }
    }
    @discardableResult private func load() async -> Bool {
        let key = requestKey
        let generation = app.generation
        let requestedPage = requested
        let readOperation = operation
        return await readFlight.run(key: key, current: { app.generation == generation && requestKey == key }) { accepted in
            failure = nil
            let ticket = page.begin(page: requestedPage)
            var args: [String: JSONValue] = ["page": .integer(requestedPage)]
            if mode != "collections" { args["uid"] = .integer(uid) }
            do {
                let result = try await app.request(readOperation, args)
                guard accepted() else { return false }
                return try page.accept(result, ticket: ticket)
            } catch {
                guard accepted() else { return false }
                failure = accountFailure(error); return false
            }
        }
    }
    private func open(_ value: JSONValue) {
        guard let id = value.nativeInt("postId") else { return }
        var args: [String: JSONValue] = ["postId": .integer(id)]
        if let floor = value["floor"], floor != .null { args["floor"] = floor }
        app.open("PostDetail", args)
    }
}

struct AccountPostRow: Identifiable { let id: String; let value: JSONValue }

struct AccountSpacePostCard: View {
    let value: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let date = value.nativeString("createdAtText") { Text(date).font(.caption).foregroundStyle(.secondary) }
            Text(value.nativeString("title") ?? value.nativeString("postTitle") ?? value.nativeInt("postId").map { "#\($0)" } ?? "")
                .font(.body.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let excerpt = value.nativeString("excerpt"), !excerpt.isEmpty {
                Text(excerpt).font(.body).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.45)
            ViewThatFits(in: .horizontal) {
                HStack { metadata }
                VStack(alignment: .leading, spacing: 8) {
                    if let board = value.nativeString("categoryTitle") { Text(board).foregroundStyle(.tint) }
                    if let count = value.nativeInt("commentCount") { Label(String(count), systemImage: "bubble.right") }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading).background(AccountSurface())
        .padding(.bottom, 8).background(AccountSurface(canvas: true)).contentShape(Rectangle())
    }
    @ViewBuilder private var metadata: some View {
        if let board = value.nativeString("categoryTitle") { Text(board).foregroundStyle(.tint) }
        Spacer(minLength: 8)
        if let count = value.nativeInt("commentCount") { Label(String(count), systemImage: "bubble.right") }
    }
}
