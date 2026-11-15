import SwiftUI
import NodysseyNativeCore

struct ContentPostList: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var categories = NativeStore()
    @StateObject private var recent = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var manageBoards = false
    @State private var category = ""
    private var sort: String { ContentPreferences(settings: app.settings).feedSort }
    @State private var page: Int64 = 1
    @State private var pageText = ""
    @State private var retry = 0
    @State private var positions = ContentFeedMemory()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { app.open("Search") } label: {
                    Label(String(localized: "content.search", table: "Content"), systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain)
                ContentSortPicker(selection: sortSelection).pickerStyle(.menu)
                    .frame(minHeight: 44).disabled(command.busy || app.settings == .null)
            }.padding(.horizontal, 16).background(ContentSurface())
            HStack(spacing: 0) {
                ContentBoardTabs(categories: homeCategories, selection: $category)
                Menu {
                    ForEach((recent.value.array?.compactMap(\.string) ?? []).filter { slug in (categories.value.array ?? []).contains { $0.nativeString("slug") == slug } }, id: \.self) { slug in
                        Button(boardTitle(slug)) { category = slug }
                    }
                    Button(String(localized: "content.manageBoards", table: "Content")) { manageBoards = true }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                        .accessibilityLabel(Text(String(localized: "content.manageBoards", table: "Content")))
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .menuIndicator(.hidden).fixedSize()
                .background(ContentSurface())
            }.background(ContentSurface())
            Divider()
            if ContentPreferences(settings: app.settings).homePageBar {
                ContentPageEntry(text: $pageText) { page = $0 }.padding(.horizontal)
            }
            ContentStoreStatus(store: categories) { retry += 1 }
            ContentCommandStatus(command: command)
            if app.site.nativeBool("requiresRestart") == true {
                Text("native_settings_site_pending", tableName: "Settings").font(.caption).foregroundStyle(.secondary)
            }
            ContentPagedList(operation: "feed", arguments: arguments, restoreID: positions.position(board: category, sort: sort)?.postID, visible: { id, page in positions.record(board: category, sort: sort, postID: id, page: page) })
                .id("\(category)|\(sort)|\(page)")
        }
        .background(ContentSurface(canvas: true))
        .navigationTitle(app.siteName ?? String(localized: "content.posts", table: "Content"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.open("Profile") } label: { Label("tab_profile", systemImage: "person.crop.circle") }
                Menu {
                    ForEach(Array(app.site.nativeArray("sites").enumerated()), id: \.offset) { _, site in
                        if let id = site.nativeString("id"), let name = site.nativeString("displayName") {
                            Button {
                                command.run(app) {
                                    _ = try await app.request("site.select", ["site": .string(id)])
                                    _ = try await app.request("site.get")
                                }
                            } label: {
                                if id == app.site.nativeString("selected") { Label(name, systemImage: "checkmark") }
                                else { Text(name) }
                            }
                        }
                    }
                    Text("native_settings_site_restart", tableName: "Settings")
                } label: { Label("action_switch_site", systemImage: "globe") }
                .disabled(command.busy)
                Button {
                    if app.isSignedIn { app.open("PostComposer", category.isEmpty ? [:] : ["boardSlug": .string(category)]) }
                    else { app.showSignIn() }
                } label: { Label(String(localized: "content.compose", table: "Content"), systemImage: "square.and.pencil") }
            }
        }
        .onChange(of: category) { _ in page = positions.position(board: category, sort: sort)?.page ?? 1 }
        .onChange(of: sort) { _ in page = positions.position(board: category, sort: sort)?.page ?? 1 }
        .onChange(of: app.generation) { _ in command.cancel(); positions = ContentFeedMemory(); page = 1 }
        .task(id: "\(app.generation)|\(retry)") { await categories.observe(app, "categories") }
        .task(id: "\(app.generation)|\(retry)") { await recent.observe(app, "boards.recent") }
        .task(id: category) {
            guard !category.isEmpty else { return }
            do { _ = try await app.request("boards.recent.record", ["categorySlug": .string(category)]) }
            catch is CancellationError { }
            catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
        }
        .sheet(isPresented: $manageBoards) { NavigationStack { ContentBoardManager(categories: categories.value, selection: $category) } }
        .task(id: app.generation) { await refreshCategories() }
        .onDisappear { command.cancel(); page = positions.position(board: category, sort: sort)?.page ?? page }
    }
    private func boardTitle(_ slug: String) -> String {
        (categories.value.array ?? []).first { $0.nativeString("slug") == slug }?.nativeString("title") ?? slug
    }
    private var sortSelection: Binding<String> {
        Binding(get: { sort }, set: { command.setFeedSort($0, app: app) })
    }
    private var homeCategories: JSONValue {
        let disabled = Set((app.settings.nativeArray("disabledHomeBoards") + app.settings.nativeArray("hiddenHomeBoards")).compactMap(\.string))
        let order = app.settings.nativeArray("homeBoardOrder").compactMap(\.string)
        let values = (categories.value.array ?? []).filter { !disabled.contains($0.nativeString("slug") ?? "") }
        return .array(values.sorted { (order.firstIndex(of: $0.nativeString("slug") ?? "") ?? Int.max) < (order.firstIndex(of: $1.nativeString("slug") ?? "") ?? Int.max) })
    }
    private var arguments: [String: JSONValue] {
        var value: [String: JSONValue] = ["sort": .string(sort), "page": .integer(page)]
        if !category.isEmpty { value["categorySlug"] = .string(category) }
        return value
    }
    private func refreshCategories() async {
        do { _ = try await app.request("categories.refresh") }
        catch is CancellationError { }
        catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
    }
}

/// Board selection remains bound to the canonical feed/paging arguments.
struct ContentBoardTabs: View {
    let categories: JSONValue
    @Binding var selection: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                tab(String(localized: "content.all", table: "Content"), slug: "")
                ForEach((categories.array ?? []).compactMap { value -> Board? in
                    guard let slug = value.nativeString("slug"), !slug.isEmpty else { return nil }
                    return Board(id: slug, title: value.nativeString("title") ?? slug)
                }) { board in tab(board.title, slug: board.id) }
            }.padding(.horizontal, 16)
        }
    }
    private func tab(_ title: String, slug: String) -> some View {
        Button { selection = slug } label: {
            Text(title).font(.subheadline.weight(selection == slug ? .semibold : .regular))
                .foregroundStyle(selection == slug ? Color.primary : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain).accessibilityAddTraits(selection == slug ? [.isSelected] : [])
    }
    private struct Board: Identifiable { let id: String; let title: String }
}

struct ContentCategoryPicker: View {
    let categories: JSONValue
    @Binding var selection: String
    var body: some View {
        Picker(String(localized: "content.board", table: "Content"), selection: $selection) {
            Text(String(localized: "content.all", table: "Content")).tag("")
            ForEach((categories.array ?? []).compactMap { value -> ContentBoard? in
                guard let slug = value.nativeString("slug"), !slug.isEmpty else { return nil }
                return ContentBoard(id: slug, title: value.nativeString("title") ?? slug)
            }) { board in Text(board.title).tag(board.id) }
        }
    }
    private struct ContentBoard: Identifiable { let id: String; let title: String }
}

struct ContentSortPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker(String(localized: "content.sort", table: "Content"), selection: $selection) {
            Text(String(localized: "content.lastReply", table: "Content")).tag("LAST_REPLY")
            Text(String(localized: "content.postTime", table: "Content")).tag("POST_TIME")
        }
    }
}

struct ContentPagedList: View {
    @EnvironmentObject private var app: NativeAppModel
    let operation: String
    let arguments: [String: JSONValue]
    var clearSearch: (() -> Void)? = nil
    @State private var authorCard: ContentIdentityRow?
    @State private var authorNavigation: AccountAuthorQuickCardNavigation?
    @State private var restoreID: Int64?
    let visible: (Int64, Int64?) -> Void
    init(operation: String, arguments: [String: JSONValue], restoreID: Int64? = nil, clearSearch: (() -> Void)? = nil, visible: @escaping (Int64, Int64?) -> Void = { _, _ in }) {
        self.operation = operation; self.arguments = arguments; self.visible = visible; self.clearSearch = clearSearch
        _restoreID = State(initialValue: restoreID)
    }
    @StateObject private var store = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var retry = 0
    @State private var restored = false
    private var window: Result<ContentPagingWindow, Error> { Result { try ContentPagingWindow(store.value) } }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ContentStoreStatus(store: store) { retry += 1 }
                ContentCommandStatus(command: command)
                loadState("prepend")
                switch window {
                case .failure(let error): NativeFailureView(failure: error as? NativeFailure ?? .init(code: "INVALID_DATA", message: "Invalid paging window"))
                case .success(let window):
                    ForEach(window.rows) { row in
                        Group {
                            if operation == "search.feed" {
                                Button { openPost(row.id, row.value) } label: {
                                    ContentSearchPostRow(value: row.value, query: arguments["query"]?.string ?? "")
                                }.buttonStyle(.plain)
                            } else {
                                ContentPostRow(value: row.value, openPost: { openPost(row.id, row.value) },
                                               openAuthor: { authorCard = ContentIdentityRow(id: $0, value: .null) })
                            }
                        }.id(row.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden).listRowBackground(ContentSurface(canvas: true))
                            .task(id: "\(window.pagerID ?? "")|\(row.globalIndex)") {
                                visible(row.id, row.page)
                                guard let arguments = window.accessArguments(for: row.id) else { return }
                                do { _ = try await app.request("paging.access", arguments) }
                                catch is CancellationError { }
                                catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
                            }
                    }
                    if window.rows.isEmpty, store.value != .null, store.value["refresh"]?.nativeString("status") == "NotLoading" {
                        NativeEmptyView(String(localized: "content.empty", table: "Content"))
                        if let clearSearch { Button("search_clear_query", action: clearSearch).frame(minHeight: 44) }
                    }
                }
                loadState("append")
                loadState("refresh")
                if let total = store.value.nativeInt("totalPages") { Text("\(total)").accessibilityLabel(Text(String(localized: "content.totalPages", table: "Content"))) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(ContentSurface(canvas: true))
            .onChange(of: store.value) { _ in
                if !restored, let restoreID, case .success(let window) = window, window.rows.contains(where: { $0.id == restoreID }) {
                    proxy.scrollTo(restoreID, anchor: .top); restored = true
                }
            }
        }
        .refreshable {
            guard let id = store.value.nativeString("pagerId") else { retry += 1; return }
            do { _ = try await app.request("paging.refresh", ["pagerId": .string(id)]) }
            catch is CancellationError { }
            catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
        }
        .task(id: "\(app.generation)|\(retry)") {
            store.invalidate()
            var args = arguments
            args["pagerId"] = .string(UUID().uuidString)
            await store.observe(app, operation, args)
        }
        .sheet(item: $authorCard, onDismiss: {
            guard let destination = authorNavigation else { return }
            authorNavigation = nil
            switch destination {
            case .signIn: app.showSignIn()
            case .route(let route, let arguments): app.open(route, arguments)
            }
        }) { row in
            AccountAuthorQuickCard(uid: row.id, onNavigate: { authorNavigation = $0; authorCard = nil })
        }
        .onChange(of: app.generation) { _ in authorNavigation = nil; authorCard = nil }
        .onDisappear { command.cancel() }
    }
    private func openPost(_ id: Int64, _ value: JSONValue) {
        app.open("PostDetail", ["postId": .integer(id), "preview": value["summary"] ?? .null])
    }
    @ViewBuilder private func loadState(_ name: String) -> some View {
        let state = store.value[name] ?? .null
        if state.nativeString("status") == "Loading" { ProgressView() }
        if state.nativeString("status") == "Error", let code = state["error"]?.nativeString("code") {
            NativeFailureView(failure: .init(code: code, message: "Operation could not be completed."), retry: {
                guard let id = store.value.nativeString("pagerId") else { retry += 1; return }
                command.run(app) { _ = try await app.request("paging.retry", ["pagerId": .string(id)]) }
            })
        }
    }
}

struct ContentSearch: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var categories = NativeStore()
    @StateObject private var users = NativeStore()
    @StateObject private var local = NativeStore()
    @StateObject private var history = NativeStore()
    @StateObject private var historyCommand = ContentCommand()
    @State private var clearHistory = false
    @State private var query: String
    @State private var submitted: String
    @State private var target = "POSTS"
    @State private var category = ""
    @State private var sort = "POST_TIME"
    @State private var retry = 0
    init(initialQuery: String?) {
        _query = State(initialValue: initialQuery ?? "")
        _submitted = State(initialValue: initialQuery ?? "")
    }
    var body: some View {
        VStack {
            Picker(String(localized: "content.target", table: "Content"), selection: $target) {
                Text(String(localized: "content.posts", table: "Content")).tag("POSTS")
                Text(String(localized: "content.users", table: "Content")).tag("USERS")
                Text(String(localized: "content.local", table: "Content")).tag("LOCAL")
            }.pickerStyle(.segmented).padding(.horizontal)
            if target == "POSTS" {
                DisclosureGroup {
                    ContentCategoryPicker(categories: categories.value, selection: $category)
                    ContentSortPicker(selection: $sort)
                    Button("search_advanced_reset") { category = ""; sort = "POST_TIME" }.frame(minHeight: 44)
                } label: { Label("search_advanced", systemImage: "line.3.horizontal.decrease") }
                .padding(.horizontal)
            }
            ContentCommandStatus(command: historyCommand)
            if submitted.isEmpty {
                List {
                    ContentStoreStatus(store: history) { retry += 1 }
                    let entries = (history.value.array ?? []).filter { $0.nativeString("target") == target }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Button {
                            query = entry.nativeString("query") ?? ""
                            submitted = query
                            category = entry.nativeString("categorySlug") ?? ""
                            sort = entry.nativeString("sort") ?? "POST_TIME"
                        } label: {
                            VStack(alignment: .leading) {
                                Text(entry.nativeString("query") ?? "")
                                if let board = entry.nativeString("categorySlug") {
                                    Text((categories.value.array ?? []).first { $0.nativeString("slug") == board }?.nativeString("title") ?? board).font(.caption)
                                }
                            }
                        }.swipeActions {
                            Button(String(localized: "content.delete", table: "Content"), role: .destructive) {
                                historyCommand.run(app) { _ = try await app.request("search.history.remove", entry.object ?? [:]) }
                            }
                        }
                    }
                    if entries.isEmpty { NativeEmptyView(String(localized: "content.searchPrompt", table: "Content")) }
                    if target != "LOCAL", !entries.isEmpty { Button(String(localized: "content.clearHistory", table: "Content"), role: .destructive) { clearHistory = true } }
                }
            }
            else if target == "POSTS" {
                ContentPagedList(operation: "search.feed", arguments: searchArguments, clearSearch: { query = ""; submitted = "" })
                    .id("\(submitted)|\(category)|\(sort)|\(retry)")
            } else {
                List {
                    if target == "USERS" {
                        ContentStoreStatus(store: users) { retry += 1 }
                        ForEach(userRows) { row in
                            Button { app.open("UserSpace", ["uid": .integer(row.id)]) } label: {
                                ContentSearchUserRow(value: row.value, query: submitted)
                            }
                        }
                        if users.value.array?.isEmpty == true { noResults }
                    } else {
                        ContentStoreStatus(store: local) { retry += 1 }
                        ForEach(localRows) { row in
                            Button { app.open("PostDetail", ["postId": .integer(row.id), "preview": row.value["summary"] ?? .null]) } label: { ContentSearchPostRow(value: row.value, query: submitted) }
                        }
                        if local.value.array?.isEmpty == true { noResults }
                    }
                }
            }
        }
        .navigationTitle(Text(String(localized: "content.search", table: "Content")))
        .searchable(text: $query, prompt: Text(String(localized: "content.searchPrompt", table: "Content")))
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines); retry += 1 }
        .task(id: app.generation) { await categories.observe(app, "categories") }
        .task(id: "\(app.generation)|\(retry)") { await history.observe(app, "search.history") }
        .task(id: "\(app.generation)|\(submitted)|\(target)|\(category)|\(sort)") {
            guard !submitted.isEmpty, target != "LOCAL" else { return }
            do {
                var args = searchArguments; args["target"] = .string(target)
                _ = try await app.request("search.history.record", args)
            } catch is CancellationError { }
            catch { historyCommand.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
        }
        .onChange(of: query) { value in if value.isEmpty { submitted = "" } }
        .confirmationDialog(String(localized: "content.clearHistory", table: "Content"), isPresented: $clearHistory) {
            Button(String(localized: "content.confirm", table: "Content"), role: .destructive) {
                historyCommand.run(app) { _ = try await app.request("search.history.clear", ["target": .string(target)]) }
            }
            Button(String(localized: "content.cancel", table: "Content"), role: .cancel) { }
        }
        .onDisappear { historyCommand.cancel() }
        .task(id: "\(app.generation)|\(submitted)|\(target)|\(retry)") {
            users.invalidate(); local.invalidate()
            guard !submitted.isEmpty else { return }
            if target == "USERS" { await users.load(app, "search.users", ["query": .string(submitted)]) }
            if target == "LOCAL" { await local.observe(app, "search.local", ["query": .string(submitted)]) }
        }
    }
    private var noResults: some View {
        VStack(spacing: 8) {
            NativeEmptyView(String(localized: "content.empty", table: "Content"))
            Button("search_clear_query") { query = ""; submitted = "" }.frame(minHeight: 44)
        }
    }
    private var searchArguments: [String: JSONValue] {
        var args: [String: JSONValue] = ["query": .string(submitted), "sort": .string(sort)]
        if !category.isEmpty { args["categorySlug"] = .string(category) }
        return args
    }
    private var userRows: [ContentIdentityRow] { ContentIdentityRow.rows(users.value.array ?? [], key: "uid") }
    private var localRows: [ContentIdentityRow] { (local.value.array ?? []).compactMap { v in
        guard let id = v["summary"]?.nativeInt("postId"), id > 0 else { return nil }
        return ContentIdentityRow(id: id, value: v)
    } }
}

struct ContentIdentityRow: Identifiable {
    let id: Int64
    let value: JSONValue
    static func rows(_ values: [JSONValue], key: String) -> [Self] {
        values.compactMap { v in guard let id = v.nativeInt(key) else { return nil }; return Self(id: id, value: v) }
    }
}
