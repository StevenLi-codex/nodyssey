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

    @State private var retry = 0
    @State private var positions = ContentFeedMemory()
    var body: some View {
        let ownerBoard = category
        let ownerSort = sort
        let ownerGeneration = app.generation
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

            ContentStoreStatus(store: categories) { retry += 1 }
            ContentCommandStatus(command: command)
            if app.site.nativeBool("requiresRestart") == true {
                Text("native_settings_site_pending", tableName: "Settings").font(.caption).foregroundStyle(.secondary)
            }
            ContentPagedList(operation: "feed", arguments: arguments,
                             restoreID: positions.position(board: category, sort: sort).flatMap { $0.page == page ? $0.postID : nil },
                             replacePage: { target in
                guard ownerGeneration == app.generation, ownerBoard == category, ownerSort == sort else { return }
                page = target
            }, visible: { id, rowPage in
                guard ownerGeneration == app.generation, ownerBoard == category, ownerSort == sort else { return }
                positions.record(board: ownerBoard, sort: ownerSort, postID: id, page: rowPage)
            })
                .id("\(app.generation)|\(category)|\(sort)|\(page)")
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
    let replacePage: ((Int64) -> Void)?
    let visible: (Int64, Int64?) -> Void
    init(operation: String, arguments: [String: JSONValue], restoreID: Int64? = nil, clearSearch: (() -> Void)? = nil, replacePage: ((Int64) -> Void)? = nil, visible: @escaping (Int64, Int64?) -> Void = { _, _ in }) {
        self.operation = operation; self.arguments = arguments; self.visible = visible; self.clearSearch = clearSearch
        self.replacePage = replacePage
        _restoreID = State(initialValue: restoreID)
        _visiblePage = State(initialValue: max(1, arguments["page"]?.int ?? 1))
    }
    @StateObject private var store = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var retry = 0
    @State private var restored = false
    @State private var owner: ContentFeedTicket?
    @State private var visiblePage: Int64
    @State private var jump = ContentFeedJump()
    @State private var pageSheet = ContentFeedSheet()
    @State private var direction = ContentFeedDirection()
    @State private var chromeHeight: CGFloat = 0
    private var isHome: Bool { operation == "feed" && replacePage != nil }
    private var totalPages: Int64 { max(1, store.value.nativeInt("totalPages") ?? 1) }
    private var showRail: Bool {
        isHome && ContentPreferences(settings: app.settings).homePageBar && totalPages > 1 && !store.value.nativeArray("items").isEmpty
    }
    private func owns(_ ticket: ContentFeedTicket) -> Bool {
        owner == ticket && ticket.generation == app.generation &&
            ticket.board == (arguments["categorySlug"]?.string ?? "") && ticket.sort == (arguments["sort"]?.string ?? "")
    }
    private var window: Result<ContentPagingWindow, Error> { Result { try ContentPagingWindow(store.value) } }
    var body: some View {
        ScrollViewReader { proxy in
          GeometryReader { viewport in
            List {
                ContentStoreStatus(store: store) { retry += 1 }
                ContentCommandStatus(command: command)
                loadState("prepend", proxy: proxy)
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
                            .background {
                                if let owner {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: ContentFeedRowsPreference.self, value: [
                                            ContentFeedVisibleRow(ticket: owner, id: row.id, page: row.page, frame: geometry.frame(in: .global))
                                        ])
                                    }
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden).listRowBackground(ContentSurface(canvas: true))
                            .task(id: "\(window.pagerID ?? "")|\(row.globalIndex)") {
                                // Row tasks are prefetch hints, never visibility observations.
                                guard let ticket = owner, owns(ticket) else { return }
                                guard let arguments = window.accessArguments(for: row.id) else { return }
                                do { _ = try await app.request("paging.access", arguments) }
                                catch is CancellationError { }
                                catch {
                                    guard owns(ticket), !Task.isCancelled else { return }
                                    command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
                                }
                            }
                    }
                    if window.rows.isEmpty, store.value != .null, store.value["refresh"]?.nativeString("status") == "NotLoading" {
                        NativeEmptyView(String(localized: "content.empty", table: "Content"))
                        if let clearSearch { Button("search_clear_query", action: clearSearch).frame(minHeight: 44) }
                    }
                }
                loadState("append", proxy: proxy)
                loadState("refresh", proxy: proxy)
                if let total = store.value.nativeInt("totalPages") { Text("\(total)").accessibilityLabel(Text(String(localized: "content.totalPages", table: "Content"))) }
                if isHome {
                    // The final row can scroll clear of the floating controls.
                    Color.clear.frame(height: chromeHeight + 24)
                        .listRowSeparator(.hidden).listRowBackground(Color.clear).accessibilityHidden(true)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(ContentSurface(canvas: true))
            .onPreferenceChange(ContentFeedRowsPreference.self) { rows in
                guard let ticket = owner, owns(ticket),
                      let first = ContentFeedViewport.firstVisible(rows, viewport: viewport.frame(in: .global), ticket: ticket),
                      case .success(let window) = window,
                      let row = window.rows.first(where: { $0.id == first.id && $0.page == first.page }) else { return }
                visible(row.id, row.page)
                if let page = row.page, page > 0 { visiblePage = page }
                direction.record(index: row.globalIndex, minY: first.frame.minY - viewport.frame(in: .global).minY)
            }
            .onChange(of: store.value) { _ in
                guard let ticket = owner, owns(ticket) else { return }
                do {
                    if let action = try jump.update(snapshot: store.value, current: ticket) {
                        perform(action, ticket: ticket, proxy: proxy)
                    }
                } catch { jump.cancel() } // The invalid window is rendered above; retire its timer.
                if !restored, let restoreID, case .success(let window) = window, window.rows.contains(where: { $0.id == restoreID }) {
                    proxy.scrollTo(restoreID, anchor: .top); restored = true
                }
            }
            .task(id: jump.wait) {
                guard let wait = jump.wait, let ticket = owner, owns(ticket) else { return }
                do {
                    // One lifecycle-owned sleeper, not a polling/request loop. Success, Error,
                    // a newer jump or invalidation changes its identity and cancels the sleep.
                    try await Task.sleep(nanoseconds: UInt64((jump.remaining(wait) * 1_000_000_000).rounded(.up)))
                    try Task.checkCancellation()
                    guard owns(ticket) else { return }
                    if let action = try jump.timeout(wait, snapshot: store.value, current: ticket) {
                        perform(action, ticket: ticket, proxy: proxy)
                    }
                } catch is CancellationError { }
                catch { if owns(ticket), jump.wait == wait { jump.cancel() } }
            }
            .overlay(alignment: .bottomTrailing) {
                if isHome {
                    homeControls(proxy: proxy).padding(12)
                        .background { GeometryReader { geometry in
                            Color.clear.preference(key: ContentFeedChromeHeightPreference.self, value: geometry.size.height)
                        } }
                }
            }
            .onPreferenceChange(ContentFeedChromeHeightPreference.self) { chromeHeight = $0 }
            .sheet(isPresented: Binding(get: { pageSheet.owner != nil }, set: { if !$0 { pageSheet.cancel() } })) {
                ContentFeedJumpSheet(page: visiblePage, total: totalPages, cancel: { pageSheet.cancel() }, go: { target in
                    guard let ticket = owner, owns(ticket), let accepted = pageSheet.take(target, current: ticket) else { return }
                    goToPage(accepted, proxy: proxy)
                })
            }
          }
        }
        .refreshable {
            guard let ticket = owner, owns(ticket) else { return }
            jump.cancel()
            guard let id = store.value.nativeString("pagerId") else { retry += 1; return }
            do { _ = try await app.request("paging.refresh", ["pagerId": .string(id)]) }
            catch is CancellationError { }
            catch {
                guard owns(ticket), !Task.isCancelled else { return }
                command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
            }
        }
        .task(id: "\(app.generation)|\(operation)|\(arguments["categorySlug"]?.string ?? "")|\(arguments["sort"]?.string ?? "")|\(retry)") {
            command.cancel()
            store.invalidate()
            let ticket = ContentFeedTicket(generation: app.generation, board: arguments["categorySlug"]?.string ?? "",
                                           sort: arguments["sort"]?.string ?? "", observation: UUID())
            owner = ticket
            jump = ContentFeedJump(owner: ticket); pageSheet.cancel(); direction = ContentFeedDirection()
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
        .onChange(of: app.generation) { generation in
            authorNavigation = nil; authorCard = nil; pageSheet.cancel()
            if owner?.generation != generation { owner = nil; jump.cancel() }
        }
        .onDisappear { command.cancel(); owner = nil; jump.cancel(); pageSheet.cancel() }
    }
    private func goToPage(_ page: Int64, proxy: ScrollViewProxy) {
        guard let ticket = owner, owns(ticket), !command.busy else { return }
        restored = true // Explicit travel wins over an old restoration anchor.
        do { perform(try jump.request(page, snapshot: store.value), ticket: ticket, proxy: proxy) }
        catch { command.failure = error as? NativeFailure ?? .init(code: "INVALID_DATA", message: "Invalid paging window") }
    }
    private func perform(_ action: ContentFeedJump.Action, ticket: ContentFeedTicket, proxy: ScrollViewProxy) {
        guard owns(ticket) else { return }
        switch action {
        case .scroll(let id): proxy.scrollTo(id, anchor: .top)
        case .replace(let target): command.cancel(); replacePage?(target)
        case .access(let arguments):
            if case .success(let window) = window, let last = window.rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            let wait = jump.wait
            command.run(app) {
                guard owns(ticket), jump.wait == wait, store.value.nativeString("pagerId") == arguments["pagerId"]?.string else { return }
                _ = try await app.request("paging.access", arguments)
            }
        case .retry(let id):
            let wait = jump.wait
            command.run(app) {
                guard owns(ticket), jump.wait == wait, store.value.nativeString("pagerId") == id else { return }
                _ = try await app.request("paging.retry", ["pagerId": .string(id)])
            }
        }
    }
    private func homeControls(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showRail {
                VStack(spacing: 4) {
                    Button { if let owner, owns(owner) { pageSheet.present(owner) } } label: {
                        VStack(spacing: 0) {
                            Text("\(visiblePage)").font(.subheadline.bold())
                            Text("/\(totalPages)").font(.caption2).foregroundStyle(.secondary)
                        }.monospacedDigit().frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(Text(String(format: NSLocalizedString("page_jump_page_of", comment: ""), visiblePage, totalPages)))
                    if direction.expanded || pageSheet.owner != nil {
                        Button { goToPage(max(1, visiblePage - 1), proxy: proxy) } label: {
                            Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44)
                        }.disabled(visiblePage <= 1).accessibilityLabel(Text("page_jump_previous"))
                        Button { goToPage(visiblePage < totalPages ? visiblePage + 1 : totalPages, proxy: proxy) } label: {
                            Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44)
                        }.disabled(visiblePage >= totalPages).accessibilityLabel(Text("page_jump_next"))
                    }
                }.buttonStyle(.bordered).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            Button {
                switch ContentFeedCompose.resolve(signedIn: app.isSignedIn, board: arguments["categorySlug"]?.string ?? "") {
                case .signIn: app.showSignIn()
                case .compose(let arguments): app.open("PostComposer", arguments)
                }
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                    if direction.expanded { Text(String(localized: "content.compose", table: "Content")) }
                }.frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle)
                .accessibilityLabel(Text(String(localized: "content.compose", table: "Content")))
        }
    }
    private func openPost(_ id: Int64, _ value: JSONValue) {
        app.open("PostDetail", ["postId": .integer(id), "preview": value["summary"] ?? .null])
    }
    @ViewBuilder private func loadState(_ name: String, proxy: ScrollViewProxy) -> some View {
        let state = store.value[name] ?? .null
        if state.nativeString("status") == "Loading" { ProgressView() }
        if state.nativeString("status") == "Error", let code = state["error"]?.nativeString("code") {
            NativeFailureView(failure: .init(code: code, message: "Operation could not be completed."), retry: {
                guard let ticket = owner, owns(ticket) else { return }
                if name == "append", let target = jump.pendingPage {
                    goToPage(target, proxy: proxy)
                    return
                }
                if name == "refresh" { jump.cancel() }
                guard let id = store.value.nativeString("pagerId") else { retry += 1; return }
                command.run(app) {
                    guard owns(ticket) else { return }
                    _ = try await app.request("paging.retry", ["pagerId": .string(id)])
                }
            })
        }
    }
}

private struct ContentFeedChromeHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ContentFeedRowsPreference: PreferenceKey {
    static let defaultValue: [ContentFeedVisibleRow] = []
    static func reduce(value: inout [ContentFeedVisibleRow], nextValue: () -> [ContentFeedVisibleRow]) {
        value.append(contentsOf: nextValue())
    }
}

/// Homepage destinations: newest is page one; unlike a thread there is no resume/floor entry.
private struct ContentFeedJumpSheet: View {
    let page: Int64
    let total: Int64
    let cancel: () -> Void
    let go: (Int64) -> Void
    @State private var entry = ContentJumpEntry()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if page > 1 {
                        Button { go(1) } label: { Label("page_jump_newest", systemImage: "arrow.up.to.line") }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }
                    if total > 1 {
                        // Original PageKeys is a horizontal strip, initially centred near the current page.
                        GeometryReader { width in
                            ScrollViewReader { keys in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 8) {
                                        ForEach(Int64(1)...max(1, total), id: \.self) { target in
                                            Button { go(target) } label: {
                                                Text("\(target)").monospacedDigit()
                                                    .frame(width: max(44, (width.size.width - 32) / 5), height: 44)
                                            }.id(target).buttonStyle(.bordered)
                                                .tint(target == page ? .accentColor : .secondary)
                                                .accessibilityAddTraits(target == page ? [.isSelected] : [])
                                        }
                                    }
                                }.onAppear { keys.scrollTo(max(1, page - 2), anchor: .leading) }
                            }
                        }.frame(height: 56)
                    }
                    HStack {
                        TextField(String(format: NSLocalizedString("page_jump_input", comment: ""), total),
                                  text: Binding(get: { entry.text }, set: { entry.update($0) }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if let target = entry.target(total: total) { go(target.page) } }
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                        Button("page_jump_go") { if let target = entry.target(total: total) { go(target.page) } }
                            .disabled(entry.target(total: total) == nil).frame(minHeight: 44)
                    }
                    // OfflineFirstPostRepository.NETWORK_PAGE_SIZE, not the number of loaded rows.
                    Text(String(format: NSLocalizedString("feed_page_size_note", comment: ""), 50))
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle(Text("page_jump_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action_cancel", action: cancel) } }
        }
        .presentationDetents([.medium, .large])
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
