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
            HStack {
                ContentCategoryPicker(categories: homeCategories, selection: $category)
                ContentSortPicker(selection: Binding(get: { sort }, set: { command.setFeedSort($0, app: app) }))
                    .disabled(command.busy || app.settings == .null)
                Menu {
                    ForEach((recent.value.array?.compactMap(\.string) ?? []).filter { slug in (categories.value.array ?? []).contains { $0.nativeString("slug") == slug } }, id: \.self) { slug in
                        Button(slug) { category = slug }
                    }
                    Button(String(localized: "content.manageBoards", table: "Content")) { manageBoards = true }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
            }.padding(.horizontal)
            if ContentPreferences(settings: app.settings).homePageBar {
                ContentPageEntry(text: $pageText) { page = $0 }.padding(.horizontal)
            }
            ContentStoreStatus(store: categories) { retry += 1 }
            ContentCommandStatus(command: command)
            ContentPagedList(operation: "feed", arguments: arguments, restoreID: positions.position(board: category, sort: sort)?.postID, visible: { id, page in positions.record(board: category, sort: sort, postID: id, page: page) })
                .id("\(category)|\(sort)|\(page)")
        }
        .navigationTitle(Text(String(localized: "content.posts", table: "Content")))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.open("Search") } label: { Label(String(localized: "content.search", table: "Content"), systemImage: "magnifyingglass") }
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
        .sheet(isPresented: $manageBoards) { NavigationStack { ContentBoardManager(categories: categories.value) } }
        .task(id: app.generation) { await refreshCategories() }
        .onDisappear { command.cancel(); page = positions.position(board: category, sort: sort)?.page ?? page }
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
    @State private var restoreID: Int64?
    let visible: (Int64, Int64?) -> Void
    init(operation: String, arguments: [String: JSONValue], restoreID: Int64? = nil, visible: @escaping (Int64, Int64?) -> Void = { _, _ in }) {
        self.operation = operation; self.arguments = arguments; self.visible = visible
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
                        Button { app.open("PostDetail", ["postId": .integer(row.id), "preview": row.value["summary"] ?? .null]) } label: { ContentPostRow(value: row.value) }
                            .buttonStyle(.plain).id(row.id)
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
                    }
                }
                loadState("append")
                loadState("refresh")
                if let total = store.value.nativeInt("totalPages") { Text("\(total)").accessibilityLabel(Text(String(localized: "content.totalPages", table: "Content"))) }
            }
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
        .onDisappear { command.cancel() }
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
                HStack { ContentCategoryPicker(categories: categories.value, selection: $category); ContentSortPicker(selection: $sort) }
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
                                if let board = entry.nativeString("categorySlug") { Text(board).font(.caption) }
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
                ContentPagedList(operation: "search.feed", arguments: searchArguments)
                    .id("\(submitted)|\(category)|\(sort)|\(retry)")
            } else {
                List {
                    if target == "USERS" {
                        ContentStoreStatus(store: users) { retry += 1 }
                        ForEach(userRows) { row in
                            Button { app.open("UserSpace", ["uid": .integer(row.id)]) } label: {
                                HStack { ContentAvatar(value: row.value); VStack(alignment: .leading) {
                                    Text(row.value.nativeString("name") ?? "")
                                    if let bio = row.value.nativeString("bio") { Text(bio).font(.caption) }
                                } }
                            }
                        }
                        if users.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
                    } else {
                        ContentStoreStatus(store: local) { retry += 1 }
                        ForEach(localRows) { row in
                            Button { app.open("PostDetail", ["postId": .integer(row.id), "preview": row.value["summary"] ?? .null]) } label: { ContentPostRow(value: row.value) }
                        }
                        if local.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
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
