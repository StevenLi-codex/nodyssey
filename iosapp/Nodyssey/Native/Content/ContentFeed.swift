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
            // This is now a single glass background. A container around the
            // foreground hoists its backdrop above the search label on iOS 26.
            Group {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        // This remains a route entry, not a second search input owner.
                        Button { app.open("Search") } label: {
                            Label(String(localized: "content.search", table: "Content"), systemImage: "magnifyingglass")
                                .foregroundStyle(NativeFeedLayout.controlForeground)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        ContentSortPicker(selection: sortSelection, readableLabel: true).pickerStyle(.menu)
                            .frame(minHeight: 44).disabled(command.busy || app.settings == .null)
                    }.padding(.horizontal, 12)
                        .padding(.vertical, 2)
                        .background { NativeGlassSurface(cornerRadius: NativeFeedLayout.chromeCornerRadius, opaque: app.settings.nativeBool("einkMode") == true, role: .homeSearch) }
                        .padding(.horizontal, NativeFeedLayout.horizontalInset)
                    HStack(spacing: 0) {
                        ContentBoardTabs(categories: homeCategories, selection: $category)
                        Menu {
                            ForEach((recent.value.array?.compactMap(\.string) ?? []).filter { slug in (categories.value.array ?? []).contains { $0.nativeString("slug") == slug } }, id: \.self) { slug in
                                Button(boardTitle(slug)) { category = slug }
                            }
                            Button(String(localized: "content.manageBoards", table: "Content")) { manageBoards = true }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44)
                                .foregroundStyle(NativeFeedLayout.controlForeground)
                                .accessibilityLabel(Text(String(localized: "content.manageBoards", table: "Content")))
                        }
                        #if os(macOS)
                        .menuStyle(.borderlessButton)
                        #endif
                        .menuIndicator(.hidden).fixedSize().tint(NativeFeedLayout.controlForeground)
                    }
                    // Secondary text rail sits directly on the page canvas.
                    .padding(.horizontal, NativeFeedLayout.horizontalInset)
                }
                .padding(.bottom, 6)
            }

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
        .task(id: "\(app.generation)|\(retry)") { categories.observeRetained(app, "categories", restart: retry) }
        .task(id: "\(app.generation)|\(retry)") { recent.observeRetained(app, "boards.recent", restart: retry) }
        .task(id: category) {
            guard !category.isEmpty else { return }
            do { _ = try await app.request("boards.recent.record", ["categorySlug": .string(category)]) }
            catch is CancellationError { }
            catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
        }
        .sheet(isPresented: $manageBoards) { NavigationStack { ContentBoardManager(categories: categories.value, selection: $category) } }
        .task(id: app.generation) { await refreshCategories() }
        .onDisappear { command.cancel() }
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
            HStack(spacing: 16) {
                tab(String(localized: "content.all", table: "Content"), slug: "")
                ForEach((categories.array ?? []).compactMap { value -> Board? in
                    guard let slug = value.nativeString("slug"), !slug.isEmpty else { return nil }
                    return Board(id: slug, title: value.nativeString("title") ?? slug)
                }) { board in tab(board.title, slug: board.id) }
            }.padding(.horizontal, 4)
        }
    }
    private func tab(_ title: String, slug: String) -> some View {
        Button { selection = slug } label: {
            Text(title).font(.subheadline.weight(selection == slug ? .semibold : .regular))
                .foregroundStyle(NativeFeedLayout.controlForeground)
                .frame(minWidth: 44, minHeight: 32)
                .overlay(alignment: .bottom) {
                    if selection == slug { Capsule().fill(.tint).frame(height: 2) }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
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
    var readableLabel = false
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        if readableLabel {
            // Like SettingsChoice, keep the native Picker's selection/checkmarks
            // but avoid its UIKit closed label retaining an earlier tint. Only
            // the home glass row opts in; search keeps the automatic control.
            Menu {
                // The home caller uses .menu for the automatic variant; do not
                // inherit that style here and accidentally add a submenu.
                picker.pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(selectedTitle)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(isEnabled ? NativeFeedLayout.controlForeground : Color.secondary)
                .padding(.horizontal, 5)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel(Text(String(localized: "content.sort", table: "Content")))
            .accessibilityValue(Text(selectedTitle))
        } else {
            picker
        }
    }
    private var selectedTitle: String {
        switch selection {
        case "LAST_REPLY": return String(localized: "content.lastReply", table: "Content")
        case "POST_TIME": return String(localized: "content.postTime", table: "Content")
        default: return selection
        }
    }
    private var picker: some View {
        Picker(String(localized: "content.sort", table: "Content"), selection: $selection) {
            Text(String(localized: "content.lastReply", table: "Content")).tag("LAST_REPLY")
            Text(String(localized: "content.postTime", table: "Content")).tag("POST_TIME")
        }
    }
}

struct ContentPagedList: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.nativePostTransition) private var postTransition
    @State private var transitionFeedID = UUID()
    let operation: String
    let arguments: [String: JSONValue]
    var clearSearch: (() -> Void)? = nil
    @State private var authorCard: ContentIdentityRow?
    @State private var authorNavigation: AccountAuthorQuickCardNavigation?
    @State private var restoreID: Int64?
    private let requestedRestoreID: Int64?
    @State private var observedArguments: [String: JSONValue]?
    let replacePage: ((Int64) -> Void)?
    let visible: (Int64, Int64?) -> Void
    init(operation: String, arguments: [String: JSONValue], restoreID: Int64? = nil, clearSearch: (() -> Void)? = nil, replacePage: ((Int64) -> Void)? = nil, visible: @escaping (Int64, Int64?) -> Void = { _, _ in }) {
        self.operation = operation; self.arguments = arguments; self.visible = visible; self.clearSearch = clearSearch
        self.replacePage = replacePage
        self.requestedRestoreID = restoreID
        _restoreID = State(initialValue: restoreID)
        _restored = State(initialValue: restoreID == nil)
        _visiblePage = State(initialValue: max(1, arguments["page"]?.int ?? 1))
    }
    @StateObject private var store = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var retry = 0
    @State private var restored = false
    @State private var isVisible = false
    @State private var owner: ContentFeedTicket?
    @State private var visiblePage: Int64
    @State private var jump = ContentFeedJump()
    @State private var pageSheet = ContentFeedSheet()
    @State private var direction = ContentFeedDirection()
    @GestureState private var feedDragging = false
    @State private var chromeHeight: CGFloat = 0
    @State private var homeTopPosition: (ticket: ContentFeedTicket, id: Int64, atTop: Bool)?
    @State private var homeTopHintSuppression: ContentFeedTicket?
    @State private var homeRefreshRequest: UInt64 = 0
    @State private var pagerRestart = 0
    @State private var observedRetry = 0
    @State private var homeRefreshCompleted: UInt64 = 0
    @State private var homeRefreshCompletedOwner: ContentFeedTicket?
    @State private var topRefreshFlight = ContentFeedTopRefreshFlight()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
              // Status, empty and pagination rows share the same canvas as post gaps.
              Group {
                ContentStoreStatus(store: store, initialLoading: true, silentRefresh: true) { retry += 1 }
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
                                               openAuthor: { authorCard = ContentIdentityRow(id: $0, value: .null) },
                                               transitionSource: isHome && postTransition != nil ? .init(feedID: transitionFeedID, postID: row.id) : nil)
                            }
                        }.id(row.id)
                            .background {
                                if let owner {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: ContentFeedRowsPreference.self, value: [
                                            ContentFeedVisibleRow(ticket: owner, id: row.id, page: row.page, frame: geometry.frame(in: .global))
                                        ])
                                    }.allowsHitTesting(false)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden).listRowBackground(ContentSurface(canvas: true))
                            .task(id: "\(window.pagerID ?? "")|\(row.globalIndex)|\(store.isReplacingPagingWindow)|\(homeTopHintSuppression == owner)") {
                                // Row tasks are prefetch hints, never visibility observations.
                                guard let ticket = owner, owns(ticket), !store.isReplacingPagingWindow,
                                      homeTopHintSuppression != ticket else { return }
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
              .listRowBackground(ContentSurface(canvas: true))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(ContentSurface(canvas: true))
            // Simultaneous observation does not replace the List's pan recognizer or
            // delay buttons. Inertia and programmatic/geometry changes never feed the rail.
            .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .updating($feedDragging) { _, dragging, _ in dragging = true }
                .onChanged { gesture in
                    guard isHome, let ticket = owner, owns(ticket) else { return }
                    // Programmatic return cannot prefetch a page; genuine new
                    // finger travel restores the existing Paging access hints.
                    homeTopHintSuppression = nil
                    direction.record(translation: gesture.translation.height)
                }
                .onEnded { _ in direction.endGesture() })
            .onChange(of: feedDragging) { dragging in
                if !dragging { direction.endGesture() } // Includes system cancellation.
            }
            .onPreferenceChange(ContentFeedRowsPreference.self) { rows in
                if isHome, let ticket = owner, owns(ticket), case .success(let window) = window, let first = window.rows.first {
                    let frame = rows.first { $0.ticket == ticket && $0.id == first.id }?.frame
                    homeTopPosition = (ticket, first.id, NativeHomeTabInteraction.isAtTop(firstMinY: frame.map { Double($0.minY) },
                                                                                       viewportMinY: Double(viewport.frame(in: .global).minY)))
                } else { homeTopPosition = nil }
                guard isVisible, restored, let ticket = owner, owns(ticket), !store.isReplacingPagingWindow,
                      let first = ContentFeedViewport.firstVisible(rows, viewport: viewport.frame(in: .global), ticket: ticket),
                      case .success(let window) = window,
                      let row = window.rows.first(where: { $0.id == first.id && $0.page == first.page }) else { return }
                visible(row.id, row.page)
                restoreID = row.id
                if let page = row.page, page > 0 { visiblePage = page }
            }
            .onReceive(app.homeScrollToTop) { _ in
                guard isHome, isVisible, app.selectedTab == .home, app.homePath.isEmpty, app.sheet == nil,
                      let ticket = owner, owns(ticket) else { return }
                // Top and loaded-empty still enter the same refresh coordinator.
                // Only a real page-one window is an immediate scroll destination.
                jump.cancel()
                if !store.isReplacingPagingWindow,
                   case .refresh(let target) = try? ContentFeedTopRefresh.plan(store.value, atTop:
                    homeTopPosition.map { $0.ticket == ticket && $0.atTop } ?? false), let target {
                    homeTopHintSuppression = ticket
                    restored = true
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.35)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                homeRefreshRequest &+= 1
            }
            .onChange(of: store.value) { _ in
                guard let ticket = owner, owns(ticket) else { return }
                let wasReplacingTop = topRefreshFlight.pending
                topRefreshFlight.update(store.value, current: ticket, failed: store.failure != nil)
                if wasReplacingTop, !topRefreshFlight.pending, !store.isReplacingPagingWindow,
                   store.failure == nil, store.value["refresh"]?.nativeString("status") == "NotLoading",
                   store.value["page"]?.int == 1, case .success(let window) = window {
                    // Replacement is the page-one read itself, not a precursor to
                    // paging.refresh. Never scroll a retained page-N placeholder.
                    restoreID = window.rows.first?.id
                    restored = true
                    if let target = restoreID {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.35)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
                do {
                    if let action = try jump.update(snapshot: store.value, current: ticket) {
                        perform(action, ticket: ticket, proxy: proxy)
                    }
                } catch { jump.cancel() } // The invalid window is rendered above; retire its timer.
                if isVisible, !store.isReplacingPagingWindow, !restored, store.failure == nil,
                   store.value["refresh"]?.nativeString("status") == "NotLoading", case .success(let window) = window {
                    // A completed window may no longer contain the saved post.
                    // Fall back once (including loaded-empty), then let viewport
                    // observations replace that stale memory with real user travel.
                    let target = restoreID.flatMap { id in window.rows.contains(where: { $0.id == id }) ? id : nil } ?? window.rows.first?.id
                    if let target { proxy.scrollTo(target, anchor: .top) }
                    restoreID = target
                    restored = true
                }
            }
            .onChange(of: homeRefreshCompleted) { _ in
                guard isVisible, let ticket = homeRefreshCompletedOwner, owns(ticket),
                      !store.isReplacingPagingWindow, case .success(let window) = window,
                      store.value["page"]?.int == 1, let first = window.rows.first, first.page == 1,
                      !(homeTopPosition.map { $0.ticket == ticket && $0.id == first.id && $0.atTop } ?? false) else { return }
                homeTopHintSuppression = ticket
                restored = true; restoreID = first.id
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: isVisible) { visible in
                // Retained observations can finish while hidden. No new value is
                // required to complete the deferred restoration on return.
                guard visible, let ticket = owner, owns(ticket), !store.isReplacingPagingWindow, !restored,
                      store.failure == nil, store.value["refresh"]?.nativeString("status") == "NotLoading",
                      case .success(let window) = window else { return }
                let target = restoreID.flatMap { id in window.rows.contains(where: { $0.id == id }) ? id : nil } ?? window.rows.first?.id
                if let target { proxy.scrollTo(target, anchor: .top) }
                restoreID = target
                restored = true
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
                        }.allowsHitTesting(false) }
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
        .nativeRefreshable(generation: app.generation,
                           scope: String(data: (try? JSONEncoder().encode([operation, arguments["categorySlug"]?.string ?? "", arguments["sort"]?.string ?? ""])) ?? Data(), encoding: .utf8) ?? "",
                           requestID: homeRefreshRequest, failure: { store.failure != nil }, completion: {
            guard let ticket = owner, owns(ticket), isVisible else { return false }
            jump.cancel()
            if isHome {
                // Both entries choose the same destination before dispatch; a
                // pull racing a tab pair cannot first refresh page N then page 1.
                if case .replace = try? ContentFeedTopRefresh.plan(store.value, atTop: true) {
                    return await refreshHomeFromPageOne(ticket)
                }
            }
            guard !store.isReplacingPagingWindow, let id = store.value.nativeString("pagerId") else { return false }
            // Pull and programmatic entry share the retained Store single-flight.
            let succeeded = await store.refreshRetained(app, "paging.refresh", ["pagerId": .string(id)], mode: .paging)
            guard succeeded, owns(ticket), !Task.isCancelled else { return false }
            if isHome { homeRefreshCompletedOwner = ticket; homeRefreshCompleted &+= 1 }
            return true
        }, action: {})
        .task(id: JSONValue.object(["generation": .integer(Int64(app.generation)), "operation": .string(operation), "arguments": .object(arguments), "retry": .integer(Int64(retry))])) {
            guard !Task.isCancelled else { return }
            // Explicit board/sort/page changes replace only the request, not the
            // List subtree. A repeated appearance keeps every presentation owner.
            let requestChanged = observedArguments != arguments
            let identityChanged = owner?.generation != app.generation ||
                owner?.board != (arguments["categorySlug"]?.string ?? "") || owner?.sort != (arguments["sort"]?.string ?? "")
            if requestChanged || identityChanged {
                topRefreshFlight.cancel()
                // A same-board page jump replaces its pager, never the old rows.
                // Board/sort/generation changes still revoke the old identity.
                if identityChanged { store.invalidate() }
                restoreID = requestedRestoreID
                restored = requestedRestoreID == nil && observedArguments == nil
                visiblePage = max(1, arguments["page"]?.int ?? 1)
                direction = ContentFeedDirection()
                homeTopPosition = nil; homeTopHintSuppression = nil
                authorNavigation = nil; authorCard = nil
            }
            var args = arguments
            if isHome, store.value != .null, !requestChanged, !identityChanged { args["page"] = .integer(visiblePage) }
            args["pagerId"] = .string(UUID().uuidString)
            if requestChanged || identityChanged || observedRetry != retry { pagerRestart += 1 }
            observedRetry = retry
            // A tab appearance is not a new feed. Keep the actual Kotlin pager,
            // loaded window and navigation ticket owned by this StateObject.
            guard store.observeRetained(app, operation, args, restart: pagerRestart) else { return }
            observedArguments = arguments
            command.cancel()
            let ticket = ContentFeedTicket(generation: app.generation, board: arguments["categorySlug"]?.string ?? "",
                                           sort: arguments["sort"]?.string ?? "", observation: UUID())
            owner = ticket
            jump = ContentFeedJump(owner: ticket); pageSheet.cancel()
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
            if owner?.generation != generation { owner = nil; jump.cancel(); topRefreshFlight.cancel() }
        }
        .onChange(of: store.failure) { failure in
            if failure != nil { topRefreshFlight.cancel() }
        }
        .onDisappear { command.cancel(); isVisible = false; direction.endGesture(); topRefreshFlight.cancel() }
        .onAppear { isVisible = true }
    }
    private func refreshHomeFromPageOne(_ ticket: ContentFeedTicket) async -> Bool {
        guard owns(ticket), isVisible else { return false }
        command.cancel(); jump.cancel(); pageSheet.cancel()
        restored = true; restoreID = nil; visiblePage = 1
        homeTopHintSuppression = ticket
        var args = arguments
        args["page"] = .integer(1)
        args["forceInitialRefresh"] = .bool(true)
        let pager = UUID().uuidString
        args["pagerId"] = .string(pager)
        let succeeded = await topRefreshFlight.wait(owner: ticket, pager: pager, start: {
            // Install the replacement before parent page binding reruns .task.
            // Its matching observedArguments/restart make that task a no-op.
            var identity = args; identity.removeValue(forKey: "pagerId"); identity.removeValue(forKey: "forceInitialRefresh")
            observedArguments = identity
            pagerRestart += 1
            guard store.observeRetained(app, operation, args, restart: pagerRestart) else {
                topRefreshFlight.cancel(); return
            }
            replacePage?(1)
        })
        return succeeded && owns(ticket) && isVisible && !Task.isCancelled
    }
    private func goToPage(_ page: Int64, proxy: ScrollViewProxy) {
        guard let ticket = owner, owns(ticket), !command.busy, !store.isReplacingPagingWindow else { return }
        homeTopHintSuppression = nil
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
        let fromHomeRoot = isHome && postTransition != nil && app.selectedTab == .home && app.homePath.isEmpty && app.sheet == nil
        app.open("PostDetail", ["postId": .integer(id), "preview": value["summary"] ?? .null])
        if fromHomeRoot, let destination = app.homePath.first {
            postTransition?.handoff.record(destination: destination,
                source: .init(feedID: transitionFeedID, postID: id), generation: app.generation)
        }
    }
    @ViewBuilder private func loadState(_ name: String, proxy: ScrollViewProxy) -> some View {
        let state = store.value[name] ?? .null
        if state.nativeString("status") == "Loading", name != "refresh", !store.isLoading { ProgressView() }
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
