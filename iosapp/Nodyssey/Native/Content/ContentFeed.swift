import SwiftUI
import NodysseyNativeCore
#if os(iOS)
import UIKit
#endif

struct ContentPostList: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var categories = NativeStore()
    @StateObject private var recent = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var manageBoards = false
    @State private var category = ""
    @State private var boardMotion = ContentFeedBoardMotion()
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    @State private var pageJumpRequest: ContentHomePageJumpIntent?
    private var sort: String { ContentPreferences(settings: app.settings).feedSort }
    @State private var page: Int64 = 1

    @State private var retry = 0
    @State private var positions = ContentFeedMemory()
    var body: some View {
        let ownerBoard = category
        let ownerSort = sort
        let ownerGeneration = app.generation
        VStack(spacing: 0) {
            if !usesHomeSafeAreaBar { homeChrome }

            ContentStoreStatus(store: categories) { retry += 1 }
            ContentCommandStatus(command: command)
            if app.site.nativeBool("requiresRestart") == true {
                Text("native_settings_site_pending", tableName: "Settings").font(.caption).foregroundStyle(.secondary)
            }
            feedWithHomeChrome { boardPages }
        }
        .background(ContentSurface(canvas: true))
        .navigationTitle(app.siteName ?? String(localized: "content.posts", table: "Content"))
        .nativeClearNavigationBar()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.open("Profile") } label: { Label("tab_profile", systemImage: "person.crop.circle") }
                Button(action: composePost) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(Text(String(localized: "content.compose", table: "Content")))
                Menu {
                    Button { pageJumpRequest = ContentHomePageJumpIntent(scope: .init(generation: ownerGeneration, board: ownerBoard, sort: ownerSort)) } label: { Label("page_jump_title", systemImage: "arrow.turn.down.right") }
                    Divider()
                    Section {
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
                    } header: { Text("action_switch_site") }
                    Text("native_settings_site_restart", tableName: "Settings")
                } label: { Image(systemName: "ellipsis").accessibilityLabel(Text("action_more")) }
                .disabled(command.busy)

            }
        }
        .onChange(of: homeBoardSlugs) { boards in
            if categories.hasValue, !boards.contains(category) { selectBoard("") }
        }
        .onChange(of: sort) { _ in pageJumpRequest = nil; page = positions.position(board: category, sort: sort)?.page ?? 1 }
        .onChange(of: app.generation) { _ in pageJumpRequest = nil; command.cancel(); positions = ContentFeedMemory(); page = 1 }
        .task(id: "\(app.generation)|\(retry)") { categories.observeRetained(app, "categories", restart: retry) }
        .task(id: "\(app.generation)|\(retry)") { recent.observeRetained(app, "boards.recent", restart: retry) }
        .task(id: category) {
            guard !category.isEmpty else { return }
            do { _ = try await app.request("boards.recent.record", ["categorySlug": .string(category)]) }
            catch is CancellationError { }
            catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
        }
        .sheet(isPresented: $manageBoards) { NavigationStack { ContentBoardManager(categories: categories.value, selection: boardSelection) } }
        .task(id: app.generation) { await refreshCategories() }
        .onDisappear { command.cancel(); pageJumpRequest = nil }
    }
    private var usesHomeSafeAreaBar: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }
    @ViewBuilder private func feedWithHomeChrome<Feed: View>(@ViewBuilder _ feed: () -> Feed) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            feed().safeAreaBar(edge: .top, spacing: 0) { homeChrome }
        } else {
            feed()
        }
        #else
        feed()
        #endif
    }
    private var homeChrome: some View {
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
                    ContentBoardTabs(categories: homeCategories, selection: boardSelection,
                                     orderedBoards: homeBoardSlugs, motion: boardMotion)
                    Menu {
                        ForEach((recent.value.array?.compactMap(\.string) ?? []).filter { slug in (categories.value.array ?? []).contains { $0.nativeString("slug") == slug } }, id: \.self) { slug in
                            Button(boardTitle(slug)) { selectBoardFromTap(slug) }
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
    private var homeBoardSlugs: [String] {
        var seen: Set<String> = [""]
        return [""] + (homeCategories.array ?? []).compactMap { $0.nativeString("slug") }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var boardSelection: Binding<String> {
        Binding(get: { category }, set: selectBoardFromTap)
    }
    private func selectBoardFromTap(_ slug: String) {
        let scope = ContentFeedBoardSwipeOwner(generation: app.generation,
            identityEpoch: app.session.nativeString("identityEpoch"), board: category, orderedBoards: homeBoardSlugs,
            isHomeRoot: app.selectedTab == .home && app.homePath.isEmpty && app.sheet == nil && !app.departureRunning,
            site: app.site.nativeString("current"), sort: sort)
        let adjacent = zip(homeBoardSlugs, homeBoardSlugs.dropFirst()).contains {
            ($0.0 == category && $0.1 == slug) || ($0.1 == category && $0.0 == slug)
        }
        boardMotion.update { $0.tap(scope: scope, target: slug, now: ProcessInfo.processInfo.systemUptime,
                                    animated: adjacent && !reduceMotion && !motionDisabled) }
        selectBoard(slug)
    }
    private func selectBoard(_ slug: String) {
        guard slug != category else { return }
        pageJumpRequest = nil
        // Restore the saved page in the same transaction as the selected tab.
        // Do not transiently open the next board with the previous board's page.
        page = positions.position(board: slug, sort: sort)?.page ?? 1
        category = slug
    }
    private func composePost() {
        switch ContentFeedCompose.resolve(signedIn: app.isSignedIn, board: category) {
        case .signIn: app.showSignIn()
        case .compose(let arguments): app.open("PostComposer", arguments)
        }
    }
    private var boardPages: some View {
        let boards = homeBoardSlugs
        let selectedIndex = boards.firstIndex(of: category) ?? 0
        let adjacentBoards = boards.enumerated().filter { abs($0.offset - selectedIndex) <= 1 }.map(\.element)
        let mountedBoards = adjacentBoards.contains(category) ? adjacentBoards : [category]
        return GeometryReader { geometry in
            ContentFeedBoardFrame(motion: boardMotion, board: category) { pose in
                let position = pose?.boardPosition ?? CGFloat(selectedIndex)
                let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
                ZStack {
                    ForEach(mountedBoards, id: \.self) { board in
                        let index = boards.firstIndex(of: board) ?? selectedIndex
                        let offset = (CGFloat(index) - position) * geometry.size.width * direction
                        boardPage(board)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .offset(x: offset)
                            .allowsHitTesting(board == category)
                            .accessibilityHidden(board != category)
                    }
                }
            }
        }
    }

    private func boardPage(_ board: String) -> some View {
        let active = board == category
        let ownerSort = sort
        let ownerGeneration = app.generation
        let saved = positions.position(board: board, sort: ownerSort)
        let boardPage = active ? page : (saved?.page ?? 1)
        var arguments: [String: JSONValue] = ["sort": .string(ownerSort), "page": .integer(boardPage)]
        if !board.isEmpty { arguments["categorySlug"] = .string(board) }

        return ContentPagedList(operation: "feed", arguments: arguments,
                                restoreID: saved.flatMap { $0.page == boardPage ? $0.postID : nil },
                                replacePage: active ? { target in
            guard ownerGeneration == app.generation, board == category, ownerSort == sort else { return }
            page = target
        } : nil, pageJumpRequest: active ? $pageJumpRequest : .constant(nil),
                                homeBoardSlugs: homeBoardSlugs, boardMotion: active ? boardMotion : nil,
                                selectHomeBoard: { target in
            guard ownerGeneration == app.generation, board == category, ownerSort == sort else { return }
            selectBoard(target)
        }, visible: { id, rowPage in
            guard ownerGeneration == app.generation, board == category, ownerSort == sort else { return }
            positions.record(board: board, sort: ownerSort, postID: id, page: rowPage)
        })
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
    let orderedBoards: [String]
    let motion: ContentFeedBoardMotion
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ContentFeedBoardFrame(motion: motion, board: selection) { presentation in
                    let boardPosition = presentation?.boardPosition
                    HStack(spacing: 16) {
                        tab(String(localized: "content.all", table: "Content"), slug: "", position: boardPosition)
                        ForEach((categories.array ?? []).compactMap { value -> Board? in
                            guard let slug = value.nativeString("slug"), !slug.isEmpty else { return nil }
                            return Board(id: slug, title: value.nativeString("title") ?? slug)
                        }) { board in tab(board.title, slug: board.id, position: boardPosition) }
                    }.padding(.horizontal, 4)
                }
            }
            .onChange(of: selection) { slug in
                withAnimation(motion.isSettling(on: slug) ? .easeOut(duration: ContentFeedBoardSwipeTrace.settleDuration) : nil) {
                    proxy.scrollTo(slug, anchor: .center)
                }
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
    private func tab(_ title: String, slug: String, position: CGFloat?) -> some View {
        Button { selection = slug } label: {
            let index = orderedBoards.firstIndex(of: slug)
            let weight = if let position, let index { max(0, 1 - abs(position - CGFloat(index))) }
                else { selection == slug ? CGFloat(1) : CGFloat(0) }
            // Both weights reserve their width; the same live rail progress
            // controls the text and underline without changing measurement.
            ZStack {
                Text(title).font(.subheadline.weight(.regular)).opacity(Double(1 - weight))
                Text(title).font(.subheadline.weight(.semibold)).opacity(Double(weight))
            }
            .accessibilityHidden(true)
            .foregroundStyle(NativeFeedLayout.controlForeground)
            .frame(minWidth: 44, minHeight: 32)
            .overlay(alignment: .bottom) {
                Capsule().fill(.tint).frame(height: 2)
                    .opacity(Double(weight)).scaleEffect(x: max(0.25, weight), y: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .id(slug).buttonStyle(.plain).accessibilityLabel(Text(title))
        .accessibilityAddTraits(selection == slug ? [.isSelected] : [])
    }
    private struct Board: Identifiable { let id: String; let title: String }
}

/// Home retains the owner without observing it. Only the rail and the existing
/// List's presentation modifier observe drag frames.
@MainActor
final class ContentFeedBoardMotion: ObservableObject {
    @Published private(set) var visual = ContentFeedBoardSwipeTrace()
    private var trace = ContentFeedBoardSwipeTrace()
    private var completion: Task<Void, Never>?

    func isSettling(on board: String) -> Bool { trace.isSettling(on: board) }

    func update(_ edit: (inout ContentFeedBoardSwipeTrace) -> Void) {
        let previous = trace.settleID
        edit(&trace)
        if trace.visualChanged(from: visual) { visual = trace }
        let next = trace.settleID
        guard previous != next else { return }
        completion?.cancel()
        completion = next.map { id in
            Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(ContentFeedBoardSwipeTrace.settleDuration * 1_000_000_000)) }
                catch { return }
                self?.update { $0.complete(id) }
            }
        }
    }
}

private struct ContentFeedBoardFrame<Frame: View>: View {
    @ObservedObject var motion: ContentFeedBoardMotion
    let board: String
    let frame: (ContentFeedBoardPresentation?) -> Frame

    init(motion: ContentFeedBoardMotion, board: String,
         @ViewBuilder frame: @escaping (ContentFeedBoardPresentation?) -> Frame) {
        self.motion = motion; self.board = board; self.frame = frame
    }

    var body: some View {
        TimelineView(.animation(paused: motion.visual.settleID == nil)) { _ in
            frame(motion.visual.presentation(board: board, now: ProcessInfo.processInfo.systemUptime))
        }
    }
}

#if os(iOS)
/// SwiftUI's iOS 16 DragGesture has no cancellation callback. Observe a separate
/// UIKit pan on the actual List instead of inferring a terminal from GestureState.
private struct ContentFeedBoardPan: UIViewRepresentable {
    enum Event {
        case began(UUID, CGPoint), changed(UUID, CGPoint), ended(UUID, CGPoint), canceled(UUID)
    }
    let receive: @MainActor (Event) -> Void

    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.receive = receive
        return anchor
    }

    func updateUIView(_ anchor: Anchor, context: Context) { anchor.receive = receive; anchor.resolve() }
    static func dismantleUIView(_ anchor: Anchor, coordinator: ()) { anchor.detach() }

    @MainActor final class Anchor: UIView, UIGestureRecognizerDelegate {
        var receive: (@MainActor (Event) -> Void)?
        private weak var scroll: UIScrollView?
        private var gesture: UUID?
        private var touchStart: CGPoint?
        private var translationCorrection = CGPoint.zero
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(sample(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delaysTouchesEnded = false
            return pan
        }()

        override func didMoveToSuperview() { super.didMoveToSuperview(); resolve() }
        override func didMoveToWindow() { super.didMoveToWindow(); resolve() }
        override func layoutSubviews() { super.layoutSubviews(); resolve() }

        func resolve() {
            guard let window, let root = owningRoot(), !bounds.isEmpty else { detach(); return }
            let frame = convert(bounds, to: window)
            var local = superview
            while let view = local {
                // Stop at the nearest unambiguous local viewport. No search in
                // other hosting controllers, rail scrolls or nested row scrolls.
                let owners = listOwners(in: view, root: root, frame: frame, window: window)
                if owners.count == 1, let owner = owners.first {
                    if scroll !== owner { detach(); scroll = owner; owner.addGestureRecognizer(pan) }
                    return
                }
                if owners.count > 1 || view === root || view is UIScrollView { break }
                local = view.superview
            }
            detach()
        }

        private func owningRoot() -> UIView? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController { return controller.viewIfLoaded }
                responder = next
            }
            return nil
        }

        private func listOwners(in view: UIView, root: UIView, frame: CGRect, window: UIWindow) -> [UIScrollView] {
            guard view !== self, !view.isHidden, view === root || !(view.next is UIViewController) else { return [] }
            if let scroll = view as? UIScrollView {
                guard scroll is UICollectionView || scroll is UITableView else { return [] }
                let viewport = scroll.convert(scroll.bounds, to: window)
                guard viewport.contains(CGPoint(x: frame.midX, y: frame.midY)),
                      abs(viewport.width - frame.width) <= 1 else { return [] }
                return [scroll]
            }
            return view.subviews.flatMap { listOwners(in: $0, root: root, frame: frame, window: window) }
        }

        func detach() {
            let previous = scroll
            let id = gesture
            gesture = nil; touchStart = nil
            scroll = nil
            previous?.removeGestureRecognizer(pan)
            if let id { receive?(.canceled(id)) }
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard recognizer === pan, let scroll, let window = scroll.window else { return false }
            var view = touch.view
            while let current = view, !(current is UIScrollView) { view = current.superview }
            guard view === scroll else { return false }
            if gesture == nil { touchStart = touch.location(in: window) }
            return true
        }

        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
            guard let window = scroll?.window, let touchStart else { return false }
            let location = pan.location(in: window)
            let x = location.x - touchStart.x, y = location.y - touchStart.y
            return x != 0 && abs(x) >= abs(y) * ContentFeedBoardSwipe.horizontalDominance
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            // This permission is only for our observer; never set failure
            // requirements, replace the List pan delegate or delay row controls.
            recognizer === pan && pan.view === scroll
        }

        @objc private func sample(_ sender: UIPanGestureRecognizer) {
            guard sender === pan, sender.view === scroll else { return }
            switch sender.state {
            case .began:
                guard gesture == nil, let window = scroll?.window, let touchStart else { return }
                let id = UUID()
                gesture = id
                let location = sender.location(in: window)
                let first = CGPoint(x: location.x - touchStart.x, y: location.y - touchStart.y)
                let raw = sender.translation(in: window)
                translationCorrection = .init(x: first.x - raw.x, y: first.y - raw.y)
                receive?(.began(id, first))
            case .changed:
                guard let id = gesture, let window = scroll?.window else { return }
                receive?(.changed(id, translation(sender, in: window)))
            case .ended, .cancelled, .failed:
                guard let id = gesture else { return }
                gesture = nil; touchStart = nil
                if sender.state == .ended, let window = scroll?.window {
                    receive?(.ended(id, translation(sender, in: window)))
                } else {
                    receive?(.canceled(id))
                }
            default: break
            }
        }

        private func translation(_ sender: UIPanGestureRecognizer, in window: UIWindow) -> CGPoint {
            let raw = sender.translation(in: window)
            return .init(x: raw.x + translationCorrection.x, y: raw.y + translationCorrection.y)
        }
    }
}
#endif

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
    @Environment(\.layoutDirection) private var layoutDirection
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
    @Binding private var pageJumpRequest: ContentHomePageJumpIntent?
    private let homeBoardSlugs: [String]
    private let boardMotion: ContentFeedBoardMotion?
    private let selectHomeBoard: ((String) -> Void)?
    init(operation: String, arguments: [String: JSONValue], restoreID: Int64? = nil,
         clearSearch: (() -> Void)? = nil, replacePage: ((Int64) -> Void)? = nil,
         pageJumpRequest: Binding<ContentHomePageJumpIntent?> = .constant(nil), homeBoardSlugs: [String] = [],
         paging: Bool = false,
         boardMotion: ContentFeedBoardMotion? = nil,
         selectHomeBoard: ((String) -> Void)? = nil,
         visible: @escaping (Int64, Int64?) -> Void = { _, _ in }) {
        self.operation = operation; self.arguments = arguments; self.visible = visible; self.clearSearch = clearSearch
        self.replacePage = replacePage
        self._pageJumpRequest = pageJumpRequest
        self.homeBoardSlugs = homeBoardSlugs
        // Inside the pager the page controller owns horizontal travel; leaving
        // the board pan on the list would let it steal the swipe.
        self.boardMotion = paging ? nil : boardMotion
        self.selectHomeBoard = selectHomeBoard
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
    @State private var visibleObservation = ContentFeedVisibleObservation()
    @State private var visiblePage: Int64
    @State private var jump = ContentFeedJump()
    @State private var pageSheet = ContentHomePageJumpSheet()
    @State private var previewMenus: Set<UUID> = []
    private var previewMenuActive: Bool { !previewMenus.isEmpty }
    @State private var homeTopPosition: (ticket: ContentFeedTicket, id: Int64, atTop: Bool)?
    @State private var homeTopHintSuppression: ContentFeedTicket?
    @State private var homeRefreshRequest: UInt64 = 0
    @State private var pagerRestart = 0
    @State private var observedRetry = 0
    @State private var homeRefreshCompleted: UInt64 = 0
    @State private var homeRefreshCompletedOwner: ContentFeedTicket?
    @State private var topRefreshFlight = ContentFeedTopRefreshFlight()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nativeCardMotionDisabled) private var motionDisabled
    private var isHome: Bool { operation == "feed" && replacePage != nil }
    private var pageJumpScope: ContentHomePageJumpScope {
        .init(generation: app.generation, board: arguments["categorySlug"]?.string ?? "",
              sort: arguments["sort"]?.string ?? "")
    }
    private var totalPages: Int64 { max(1, store.value.nativeInt("totalPages") ?? 1) }
    private var allowsPostPreview: Bool {
        isHome && isVisible && app.selectedTab == .home && app.homePath.isEmpty &&
            app.sheet == nil && !app.departureRunning && pageSheet.owner == nil && authorCard == nil
    }
    private var boardSwipeContext: ContentFeedBoardSwipeContext {
        let scope = ContentFeedBoardSwipeOwner(generation: pageJumpScope.generation,
            identityEpoch: app.session.nativeString("identityEpoch"), board: pageJumpScope.board,
            orderedBoards: homeBoardSlugs, isHomeRoot: allowsPostPreview && !previewMenuActive,
            site: app.site.nativeString("current"), sort: pageJumpScope.sort)
        // Until the keyed task owns the rendered arguments, the old pager
        // cannot authorize a newly started gesture (including same-board pages).
        let current = observedArguments == arguments ? scope.admitted(scope: pageJumpScope, ticket: owner) : nil
        return .init(scope: scope, current: current)
    }
    private var animateBoardSwipe: Bool { !reduceMotion && !motionDisabled }
    private func owns(_ ticket: ContentFeedTicket) -> Bool {
        owner == ticket && ticket.generation == app.generation &&
            ticket.board == (arguments["categorySlug"]?.string ?? "") && ticket.sort == (arguments["sort"]?.string ?? "")
    }
    @StateObject private var windowProjection = NativeRenderingMemo<NativeRenderingInput<JSONValue>, Result<ContentPagingWindow, Error>>()
    private var window: Result<ContentPagingWindow, Error> {
        windowProjection.value(for: .init(
            app: ObjectIdentifier(app), generation: app.generation,
            identityEpoch: app.session.nativeString("identityEpoch"), content: store.value
        )) {
            Result { try ContentPagingWindow(store.value) }
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
          GeometryReader { viewport in
            let presented = pageSheet.presentation
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
                                               transitionSource: isHome && postTransition != nil ? .init(feedID: transitionFeedID, postID: row.id) : nil,
                                               previewItem: allowsPostPreview ? ContentPostPreviewItem(postID: row.id,
                                                   summary: row.value["summary"] ?? row.value, routeIdentity: row.value,
                                                   onCommit: { openPost(row.id, row.value) },
                                                   onMenuStateChanged: { menu, active in
                                                       if active { previewMenus.insert(menu); boardMotion?.update { $0.revoke() } }
                                                       else { previewMenus.remove(menu) }
                                                   }) : nil)
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
                if operation != "feed", let total = store.value.nativeInt("totalPages") { Text("\(total)").accessibilityLabel(Text(String(localized: "content.totalPages", table: "Content"))) }
              }
              .listRowBackground(ContentSurface(canvas: true))
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(ContentSurface(canvas: true))
            #if os(iOS)
            .background {
                if let boardMotion {
                    ContentFeedBoardPan { event in handleBoardPan(event, motion: boardMotion, pageWidth: viewport.size.width) }
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            #endif
            // This separate gesture only restores the existing vertical Paging hints.
            .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
                .onChanged { gesture in
                    // Programmatic return cannot prefetch a page; genuine new
                    // vertical finger travel restores the existing Paging access hints.
                    if isHome, !previewMenuActive, let ticket = owner, owns(ticket),
                       abs(gesture.translation.height) > abs(gesture.translation.width) {
                        homeTopHintSuppression = nil
                    }
                })
            .onChange(of: boardSwipeContext) { context in
                boardMotion?.update { $0.synchronize(context) }
            }
            .onChange(of: animateBoardSwipe) { _ in boardMotion?.update { $0.revoke() } }
            .onChange(of: pageJumpRequest) { _ in presentRequestedPageJump() }
            .onChange(of: owner) { _ in presentRequestedPageJump() }
            .onChange(of: pageJumpScope) { scope in
                if pageJumpRequest?.scope != scope { pageJumpRequest = nil }
                if let ticket = pageSheet.owner, !scope.contains(ticket) { pageSheet.cancel() }
            }
            .onPreferenceChange(ContentFeedRowsPreference.self) { rows in
                let currentWindow = window
                if isHome, let ticket = owner, owns(ticket), case .success(let currentWindow) = currentWindow, let first = currentWindow.rows.first {
                    let frame = rows.first { $0.ticket == ticket && $0.id == first.id }?.frame
                    let atTop = NativeHomeTabInteraction.isAtTop(firstMinY: frame.map { Double($0.minY) },
                                                                  viewportMinY: Double(viewport.frame(in: .global).minY))
                    if homeTopPosition?.ticket != ticket || homeTopPosition?.id != first.id || homeTopPosition?.atTop != atTop {
                        homeTopPosition = (ticket, first.id, atTop)
                    }
                } else if homeTopPosition != nil { homeTopPosition = nil }
                guard isVisible, restored, let ticket = owner, owns(ticket), !store.isReplacingPagingWindow,
                      let first = ContentFeedViewport.firstVisible(rows, viewport: viewport.frame(in: .global), ticket: ticket),
                      case .success(let currentWindow) = currentWindow,
                      let row = currentWindow.rows.first(where: { $0.id == first.id && $0.page == first.page }) else { return }
                // Do not open a mutable @State access on every pixel of travel.
                // Commit its new observation only when the visible identity changes.
                var nextObservation = visibleObservation
                guard nextObservation.shouldPublish(first, current: ticket) else { return }
                visibleObservation = nextObservation
                if restoreID != row.id { restoreID = row.id }
                if let page = row.page, page > 0, visiblePage != page { visiblePage = page }
                visible(row.id, row.page)
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
                    withAnimation((reduceMotion || motionDisabled) ? nil : .easeInOut(duration: 0.35)) {
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
                        withAnimation((reduceMotion || motionDisabled) ? nil : .easeInOut(duration: 0.35)) {
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
                withAnimation((reduceMotion || motionDisabled) ? nil : .easeInOut(duration: 0.35)) {
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
            .sheet(isPresented: Binding(get: { presented != nil && pageSheet.presentation == presented }, set: { shown in
                if !shown { pageSheet.dismiss(presented, current: owner, scope: pageJumpScope) }
            })) {
                ContentFeedJumpSheet(page: visiblePage, total: totalPages, cancel: {
                    pageSheet.dismiss(presented, current: owner, scope: pageJumpScope)
                }, go: { target in
                    guard let accepted = pageSheet.take(target, presented: presented, current: owner,
                                                       scope: pageJumpScope) else { return }
                    goToPage(accepted, proxy: proxy)
                }).id(presented?.id)
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
                    return await refreshFromPageOne(ticket)
                }
            } else {
                // A board keeps its own pager id, so paging.refresh only re-reads
                // the window this client already holds: the list redraws without
                // fetching anything newer. Refreshing a board means the same
                // forced page-one read the combined feed uses, against that
                // board's own arguments.
                return await refreshFromPageOne(ticket)
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
                boardMotion?.update { $0.synchronize(boardSwipeContext) }
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
            boardMotion?.update { $0.synchronize(boardSwipeContext) }
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
            authorNavigation = nil; authorCard = nil; pageSheet.cancel(); boardMotion?.update { $0.revoke() }
            if owner?.generation != generation { owner = nil; jump.cancel(); topRefreshFlight.cancel() }
        }
        .onChange(of: store.failure) { failure in
            if failure != nil { topRefreshFlight.cancel() }
        }
        .onDisappear { command.cancel(); isVisible = false; pageJumpRequest = nil; pageSheet.cancel(); boardMotion?.update { $0.cancel() }; topRefreshFlight.cancel() }
        .onAppear { isVisible = true }
    }
    #if os(iOS)
    private func handleBoardPan(_ event: ContentFeedBoardPan.Event, motion: ContentFeedBoardMotion, pageWidth: CGFloat) {
        let context = boardSwipeContext
        let now = ProcessInfo.processInfo.systemUptime
        var target: String?
        motion.update { trace in
            switch event {
            case .began(let id, let point):
                trace.begin(gesture: id, context: context, x: point.x, y: point.y,
                            rightToLeft: layoutDirection == .rightToLeft, now: now, animated: animateBoardSwipe, pageWidth: pageWidth)
            case .changed(let id, let point):
                trace.change(gesture: id, context: context, x: point.x, y: point.y)
            case .ended(let id, let point):
                target = trace.finish(gesture: id, context: context, x: point.x, y: point.y, now: now)
            case .canceled(let id):
                trace.cancel(gesture: id, now: now)
            }
        }
        if let target { selectHomeBoard?(target) }
    }
    #endif
    private func refreshFromPageOne(_ ticket: ContentFeedTicket) async -> Bool {
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
            boardMotion?.update { $0.revoke() }
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
    private func presentRequestedPageJump() {
        guard isHome, let ticket = ContentHomePageJumpIntent.take(&pageJumpRequest,
            current: pageJumpScope, owner: owner) else { return }
        pageSheet.present(ticket)
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
