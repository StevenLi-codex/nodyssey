import SwiftUI
import NodysseyNativeCore
#if canImport(UIKit)
import UIKit
#endif

struct ContentPostDetail: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.nativeDestinationID) private var destinationID
    @Environment(\.scenePhase) private var scenePhase
    let postID: Int64
    let initialFloor: String?
    let initialPage: Int64?
    var preview: JSONValue? = nil
    @StateObject private var thread = NativeStore()
    @StateObject private var tracked = NativeStore()
    @StateObject private var command = ContentThreadCommand()
    @StateObject private var replyOwner = EditorReplyLifetime()
    @State private var departureToken: UUID?
    @State private var retry = 0
    @State private var loadRetry = 0
    @State private var target: ContentReadingTarget?
    @State private var targetBottom = false
    @State private var visibleTarget: ContentReadingTarget?
    @State private var resume: ContentReadingTarget?
    @State private var firstNewFloor: Int64?
    @State private var pageLoad = ContentThreadPageLoad()
    private var loadingPage: Bool { pageLoad.loading }
    @State private var refreshSucceeded = false
    @State private var loadRequest: PageRequest?
    @State private var expanded = Set<String>()
    @State private var reaction: PendingReaction?
    @State private var allowance: JSONValue = .null
    @State private var jumpPresented = false
    @State private var railExpanded = true
    @State private var railClearance: CGFloat = 0
    @State private var hasRead = false
    @State private var titleOffscreen = false
    @State private var selectedFloor: FloorSelection?
    @State private var afterFloorDismiss: (() -> Void)?
    @State private var author: AuthorSelection?
    @State private var authorNavigation: AccountAuthorQuickCardNavigation?
    private var args: [String: JSONValue] { ["postId": .integer(postID)] }
    private var firstPage: Int64 { thread.value.nativeInt("firstLoadedPage") ?? 1 }
    private var lastPage: Int64 { thread.value.nativeInt("lastLoadedPage") ?? 1 }
    private var totalPages: Int64 { max(1, thread.value.nativeInt("totalPages") ?? 1) }
    private var currentPage: Int64 { min(totalPages, visibleTarget?.page ?? target?.page ?? firstPage) }
    private var title: String { thread.value.nativeString("title") ?? preview?["summary"]?.nativeString("title") ?? preview?.nativeString("title") ?? "" }
    private var covered: Bool {
        guard let destinationID else { return false }
        let active: UUID?
        if let sheet = app.sheet { active = app.sheetPath.last?.id ?? sheet.id }
        else {
            switch app.selectedTab {
            case .home: active = app.homePath.last?.id
            case .notifications: active = app.notificationsPath.last?.id
            case .profile: active = app.profilePath.last?.id
            }
        }
        return active != destinationID
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ContentStoreStatus(store: thread) { retry += 1 }
                        ContentCommandStatus(command: command)
                        if command.reactionsBlocked {
                            Button(CT("reload")) { command.run(app) { await command.reconcileReactions(app, postID: postID) } }
                                .disabled(loadingPage || command.busy).padding()
                        }
                        openingCard.id("#0").modifier(ContentThreadFrame(id: "#0"))
                        if thread.value != .null {
                            HStack {
                                Text(String(format: CT("replyCount"), commentRows.count)).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(CT("autoPaging")).font(.caption).foregroundStyle(.secondary)
                            }.padding(.horizontal, 18).padding(.vertical, 12)
                            if commentRows.isEmpty { Text(CT("emptyReplies")).foregroundStyle(.secondary).padding(18) }
                            ForEach(commentRows) { row in
                                VStack(alignment: .leading, spacing: 0) {
                                    if row.id == firstNewRowID {
                                        Label(CT("newReplies"), systemImage: "sparkles").font(.caption).foregroundStyle(.tint).padding(.horizontal, 18).padding(.vertical, 8)
                                    }
                                    commentRow(row)
                                }.id(row.scrollID).modifier(ContentThreadFrame(id: row.id))
                            }
                            if loadingPage { ProgressView().frame(maxWidth: .infinity).padding() }
                            if lastPage >= totalPages {
                                Button(CT("refreshTail")) { load(page: lastPage, extend: true) }
                                    .frame(maxWidth: .infinity, minHeight: 44).disabled(loadingPage)
                            }
                        } else if !thread.isLoading && !loadingPage && thread.failure == nil {
                            NativeEmptyView(CT("noCachedThread"))
                            Button(CT("reload")) { loadRetry += 1 }.padding()
                        }
                        // A high-water clearance, never the collapsed rail's smaller height.
                        Color.clear.frame(height: railClearance + 24).id("thread.bottom")
                    }
                }
                .coordinateSpace(name: "thread.viewport")
                .onPreferenceChange(ContentThreadFrames.self) { frames in updateViewport(frames, height: viewport.size.height) }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in hasRead = true; railExpanded = false })
                .overlay(alignment: .bottomTrailing) {
                    if !replyOwner.visible && !covered {
                        ContentThreadPageRail(page: currentPage, total: totalPages,
                            expanded: railExpanded || jumpPresented || command.failure != nil,
                            enabled: thread.value != .null,
                            previous: { jump(.init(floor: nil, page: currentPage - 1)) },
                            next: { jump(.init(floor: nil, page: currentPage + 1)) },
                            jump: { jumpPresented = true }, reply: { reply(nil) })
                            .background(GeometryReader { geometry in Color.clear.preference(key: ContentThreadRailHeight.self, value: geometry.size.height) })
                            .padding(16)
                    }
                }
                .onPreferenceChange(ContentThreadRailHeight.self) { railClearance = max(railClearance, $0) }
            }
            .onChange(of: thread.value) { _ in restoreScroll(proxy) }
            .onChange(of: target) { _ in restoreScroll(proxy) }
            .onChange(of: loadingPage) { _ in restoreScroll(proxy) }
        }
        .nativePageCanvas()
        .navigationTitle(titleOffscreen ? title : CT("thread"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openBrowser() } label: { Label(CT("openOriginal"), systemImage: "safari") }
                Menu {
                    Button(CT("reload")) { load(page: currentPage, extend: true) }
                    Button(CT("track")) { toggleTracking() }
                    Button(CT("all")) { app.open("TrackedThreads") }
                    ContentShareLink(postID: postID, page: currentPage, floor: visibleTarget?.floor)
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .nativeRefreshable(generation: app.generation,
            failure: { thread.failure != nil }, completion: { refreshSucceeded }) {
                refreshSucceeded = false
                let generation = app.generation
                let completed = await loadPage(firstPage, extend: true)
                guard !Task.isCancelled, generation == app.generation else { return }
                refreshSucceeded = completed
            }
        .task(id: "\(app.generation)|\(retry)") { await thread.observe(app, "thread", args) }
        .task(id: "\(app.generation)|\(retry)") { await tracked.observe(app, "tracked.observe") }
        .task(id: "\(app.generation)|\(loadRetry)") { await openThread() }
        .task(id: loadRequest) { if let request = loadRequest { await loadPage(request.page, extend: request.extend) } }
        .task(id: visibleTarget) {
            guard hasRead, target == nil, let position = visibleTarget, thread.value != .null else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                var value = args; value["page"] = .integer(position.page)
                if let floor = position.floor { value["floor"] = .string(floor) }
                _ = try await app.request("thread.position.set", value)
            } catch is CancellationError { }
            catch { command.failure = contentFailure(error) }
        }
        .sheet(isPresented: $jumpPresented) {
            ContentThreadJumpSheet(page: currentPage, total: totalPages,
                loadedCount: commentRows.count + (thread.value["body"] == .null || thread.value["body"] == nil ? 0 : 1),
                resume: (resume ?? .init(floor: nil, page: lastPage)).clamped(to: totalPages)) { destination, bottom in
                    jumpPresented = false; jump(destination, bottom: bottom)
                }
        }
        .sheet(item: $selectedFloor, onDismiss: { let action = afterFloorDismiss; afterFloorDismiss = nil; action?() }) { selection in
            floorActionSheet(selection)
        }
        .sheet(item: $author, onDismiss: navigateFromAuthor) { selected in
            AccountAuthorQuickCard(uid: selected.id, onNavigate: { destination in authorNavigation = destination; author = nil })
        }
        .modifier(EditorThreadReplyPresentation(owner: replyOwner, covered: covered, onPublished: published))
        .confirmationDialog(CT("reactionConfirm"), isPresented: Binding(get: { reaction != nil }, set: { if !$0 { reaction = nil } })) {
            Button(CT("confirm")) { if let reaction { self.reaction = nil; sendReaction(reaction) } }
            Button(CT("cancel"), role: .cancel) { reaction = nil }
        } message: {
            if reaction?.action == "Dislike" { Text(CT("dislikeCost")) }
            else if let remaining = allowance.nativeInt("remaining"), remaining > 0 { Text(CT("freeLegAvailable")) }
            else { Text(CT("legCost")) }
        }
        .onAppear {
            if departureToken == nil, let destinationID {
                departureToken = app.registerDismissal(destinationID: destinationID,
                    close: { await replyOwner.prepareDeparture() }, revoke: { replyOwner.invalidate() },
                    terminate: { replyOwner.terminateAfterPrepared() }, validate: { replyOwner.isDeparturePreparationValid })
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active, let model = replyOwner.model {
                model.focus.handoff { Task { do { try await model.flush() } catch { model.report(error) } } }
            }
        }
        .onChange(of: app.generation) { _ in
            replyOwner.invalidate(); command.cancel(); reaction = nil; allowance = .null
            resume = nil; expanded = []; visibleTarget = nil; author = nil; selectedFloor = nil
            authorNavigation = nil; afterFloorDismiss = nil; loadRequest = nil
        }
        .onDisappear { pageLoad.depart(); command.cancel() }
    }

    private struct CommentRow: Identifiable {
        let id: String; let value: JSONValue; let page: Int64
        var scrollID: String { value.nativeString("floor") ?? id }
    }
    private struct FloorSelection: Identifiable { let id: String; let opening: Bool }
    private struct AuthorSelection: Identifiable { let id: Int64 }
    private struct PageRequest: Equatable { let id = UUID(); let page: Int64; let extend: Bool }
    private var commentRows: [CommentRow] {
        let pages = thread.value.nativeArray("commentPages")
        return thread.value.nativeArray("comments").enumerated().map { index, value in
            let id = value.nativeInt("commentId").map { "comment:\($0)" } ?? value.nativeString("floor").map { "floor:\($0)" } ?? "unidentified:\(index)"
            return CommentRow(id: id, value: value, page: pages.indices.contains(index) ? pages[index].int ?? firstPage : firstPage)
        }
    }
    private var firstNewRowID: String? {
        guard let firstNewFloor else { return nil }
        return commentRows.first { ($0.value.nativeString("floor").flatMap(ContentReadingTarget.floorNumber) ?? -1) >= firstNewFloor }?.id
    }
    private func identity(_ value: JSONValue, opening: Bool) -> String {
        opening ? "#0" : value.nativeInt("commentId").map { "comment:\($0)" } ?? value.nativeString("floor").map { "floor:\($0)" } ?? "unknown"
    }
    private func blocked(_ value: JSONValue, opening: Bool) -> Bool {
        value.nativeBool("isBlocked") == true && !expanded.contains(identity(value, opening: opening))
    }
    private var openingCard: some View {
        let body = thread.value["body"].flatMap { $0 == .null ? nil : $0 }
        let summary = preview?["summary"] ?? preview
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let category = body?.nativeString("categoryTitle") ?? summary?.nativeString("categoryTitle") { Text(category).foregroundStyle(.tint) }
                    if thread.value.nativeBool("isAwarded") == true { Label(CT("awarded"), systemImage: "diamond") }
                }.font(.caption.weight(.medium))
                Text(title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityAddTraits(.isHeader).modifier(ContentThreadFrame(id: "thread.title"))
            }.modifier(ContentThreadOpeningBand(prominent: true))
            if let body {
                if blocked(body, opening: true) { reveal(body, opening: true).padding(14) }
                else {
                    HStack(alignment: .top, spacing: 8) {
                        authorButton(body, size: 28)
                        metadata(body).frame(maxWidth: .infinity, alignment: .leading)
                    }.onLongPressGesture { selectedFloor = .init(id: "#0", opening: true) }
                        .modifier(ContentThreadOpeningBand())
                    // Opaque reading plane: only the surrounding title/author bands carry tint.
                    VStack(alignment: .leading, spacing: 10) {
                        richBody(body, opening: true)
                        floorActions(body, page: 1, opening: true)
                    }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ContentSurface())
                }
            } else if thread.value != .null {
                Button(CT("openOriginal")) { jump(.init(floor: "#0", page: 1)) }.frame(minHeight: 44).padding(.horizontal, 14)
            } else {
                if let summary {
                    HStack { ContentAvatar(value: summary, size: 28); Text(summary.nativeString("authorName") ?? "").font(.subheadline) }
                        .modifier(ContentThreadOpeningBand())
                }
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(ContentSurface())
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8).padding(.top, 8)
    }
    private func commentRow(_ row: CommentRow) -> some View {
        VStack(spacing: 0) {
            if blocked(row.value, opening: false) { reveal(row.value, opening: false).padding(18).frame(maxWidth: .infinity, alignment: .leading) }
            else {
                HStack(alignment: .top, spacing: 8) {
                    authorButton(row.value, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        metadata(row.value).onLongPressGesture { selectedFloor = .init(id: row.id, opening: false) }
                        richBody(row.value, opening: false)
                        floorActions(row.value, page: row.page, opening: false)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 4)
            }
            Divider().padding(.horizontal, 8)
        }
    }
    private func reveal(_ value: JSONValue, opening: Bool) -> some View {
        Button { expanded.insert(identity(value, opening: opening)) } label: {
            Label(CT("revealBlocked"), systemImage: "eye.slash").frame(minHeight: 44)
        }
    }
    @ViewBuilder private func richBody(_ value: JSONValue, opening: Bool) -> some View {
        let floor = value.nativeString("floor") ?? (opening ? "#0" : nil)
        ContentRichBody(value: value["nodes"] ?? .array([]), postID: postID, threadTitle: title, floor: floor,
            jump: { jump(.init(floor: $0, page: nil)) })
            .id("\(postID)|\(identity(value, opening: opening))|body")
        if !value.nativeArray("signatureNodes").isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                ContentRichBody(value: value["signatureNodes"] ?? .array([]), postID: postID, threadTitle: title,
                    floor: floor, role: .signature, jump: { jump(.init(floor: $0, page: nil)) })
            }.padding(.top, 4)
        }
    }
    private func authorButton(_ value: JSONValue, size: CGFloat) -> some View {
        Button { if let uid = value.nativeInt("authorUid"), uid > 0 { author = .init(id: uid) } } label: {
            ContentAvatar(value: value, size: size).frame(minWidth: 44, minHeight: 44, alignment: .top)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(value.nativeInt("authorUid") == nil)
            .accessibilityLabel(value.nativeString("authorName") ?? "")
    }
    private func metadata(_ value: JSONValue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { if let uid = value.nativeInt("authorUid"), uid > 0 { author = .init(id: uid) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(value.nativeString("authorName") ?? "").fontWeight(.semibold) + Text(badgeText(value)).foregroundColor(.secondary))
                        .font(.subheadline)
                    if let time = value.nativeString("createdAtText") { Text(time).font(.caption).foregroundStyle(.secondary) }
                    if value.nativeBool("isEdited") == true { Text(CT("edited") + " " + (value.nativeString("editedAtText") ?? "")).font(.caption).foregroundStyle(.secondary) }
                }.frame(minHeight: 44, alignment: .leading).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled((value.nativeInt("authorUid") ?? 0) <= 0)
            Spacer(minLength: 2)
            if let label = value.nativeString("floor") { Text(label).font(.caption).foregroundStyle(.secondary).monospacedDigit().padding(.top, 4) }
        }
    }
    private func badgeText(_ value: JSONValue) -> String {
        var badges = value.nativeArray("badges").compactMap(\.string)
        if value.nativeBool("isOriginalPoster") == true, !badges.contains(CT("originalPoster")) { badges.insert(CT("originalPoster"), at: 0) }
        return badges.isEmpty ? "" : " · " + badges.joined(separator: " · ")
    }
    private func floorActions(_ value: JSONValue, page: Int64, opening: Bool) -> some View {
        HStack(spacing: 8) {
            if let id = value.nativeInt("commentId") {
                reactionButton("Upvote", field: "upvoted", count: "upvoteCount", symbol: "hand.thumbsup", value: value, commentID: id, page: page, opening: opening)
                reactionButton("ChickenLeg", field: "liked", count: "likeCount", symbol: "gift", value: value, commentID: id, page: page, opening: opening)
            }
            if opening { collectButton }
            else if value.nativeBool("isMine") == true {
                Button { edit(value, page: page, opening: false) } label: { Label(CT("edit"), systemImage: "square.and.pencil").frame(minHeight: 44) }
                    .disabled(value.nativeInt("commentId") == nil)
            } else {
                Button { reply(value) } label: { Label(CT("reply"), systemImage: "arrowshape.turn.up.left").frame(minHeight: 44) }
            }
            Spacer(minLength: 0)
            Button { selectedFloor = .init(id: identity(value, opening: opening), opening: opening) } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel(CT("floorActions"))
        }.font(.caption).foregroundStyle(.secondary).buttonStyle(.plain).disabled(command.busy)
            .onLongPressGesture { selectedFloor = .init(id: identity(value, opening: opening), opening: opening) }
    }
    private var collectButton: some View {
        Button {
            guard app.isSignedIn else { app.showSignIn(); return }
            guard let collected = thread.value.nativeBool("collected") else { return }
            command.run(app) {
                _ = try await app.request("thread.collect", ["postId": .integer(postID), "collected": .bool(!collected)])
                _ = try await app.request("thread.get", args)
            }
        } label: {
            Label(thread.value.nativeInt("collectionCount").map(String.init) ?? CT("bookmark"), systemImage: thread.value.nativeBool("collected") == true ? "bookmark.fill" : "bookmark").frame(minHeight: 44)
        }.disabled(thread.value.nativeBool("collected") == nil)
    }
    @ViewBuilder private func floorActionSheet(_ selection: FloorSelection) -> some View {
        let row = commentRows.first { $0.id == selection.id }
        let value = selection.opening ? thread.value["body"] : row?.value
        if let value, value != .null, !blocked(value, opening: selection.opening) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        ContentAvatar(value: value, size: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text((value.nativeString("authorName") ?? "") + " · " + (value.nativeString("floor") ?? "#0")).font(.subheadline.weight(.semibold))
                            Text(ContentQuoteContext.text(value["nodes"] ?? .array([]))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    if let id = value.nativeInt("commentId") {
                        HStack(alignment: .top) {
                            reactionTile("Upvote", field: "upvoted", count: "upvoteCount", symbol: "hand.thumbsup", value: value, id: id, page: row?.page ?? 1, opening: selection.opening, price: CT("free"))
                            reactionTile("ChickenLeg", field: "liked", count: "likeCount", symbol: "gift", value: value, id: id, page: row?.page ?? 1, opening: selection.opening, price: allowance.nativeInt("remaining").map { $0 > 0 ? CT("freeLegAvailable") : CT("legCost") } ?? CT("legCost"))
                            reactionTile("Dislike", field: "disliked", count: "dislikeCount", symbol: "hand.thumbsdown", value: value, id: id, page: row?.page ?? 1, opening: selection.opening, price: CT("dislikeCost"))
                        }
                    }
                    if value.nativeBool("isMine") == true {
                        Button(CT("edit")) { dismissFloor { edit(value, page: row?.page ?? 1, opening: selection.opening) } }.disabled(value.nativeInt("commentId") == nil)
                    } else {
                        Button(CT("reply")) { dismissFloor { reply(value) } }
                    }
                    Button(CT("quote")) { dismissFloor { reply(value, quoting: true) } }.disabled(value.nativeString("floor").flatMap(ContentReadingTarget.floorNumber) == nil)
                    ContentShareLink(postID: postID, page: row?.page ?? 1, floor: value.nativeString("floor") ?? (selection.opening ? "#0" : nil),
                        shareContext: .init(content: value, threadTitle: title, openingPost: selection.opening, revealedBlocked: expanded.contains(selection.id)))
                    Text(CT("reactionIrreversible")).font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.bordered).padding(16)
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else { NativeEmptyView(CT("unavailableFloor")) }
    }
    private func reactionTile(_ action: String, field: String, count: String, symbol: String, value: JSONValue, id: Int64, page: Int64, opening: Bool, price: String) -> some View {
        VStack(spacing: 4) {
            reactionButton(action, field: field, count: count, symbol: symbol, value: value, commentID: id, page: page, opening: opening, fromSheet: true)
            Text(CT(action)).font(.caption.weight(.medium))
            Text(price).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
    private func dismissFloor(_ action: @escaping () -> Void) { afterFloorDismiss = action; selectedFloor = nil }
    private func reactionButton(_ action: String, field: String, count: String, symbol: String, value: JSONValue, commentID: Int64, page: Int64, opening: Bool, fromSheet: Bool = false) -> some View {
        let spent = value["reactions"]?.nativeBool(field) == true
        let known = value["reactions"]?.nativeBool(field) != nil
        return Button {
            let perform = { beginReaction(PendingReaction(commentID: commentID, action: action, page: page, opening: opening), spent: spent) }
            if fromSheet { dismissFloor(perform) } else { perform() }
        } label: {
            Label(value["reactions"]?.nativeInt(count).map(String.init) ?? "—", systemImage: spent ? symbol + ".fill" : symbol)
                .frame(minWidth: 44, minHeight: 44)
        }.disabled(!known || spent || command.reactionsBlocked || command.busy)
            .accessibilityLabel(CT(action))
    }
    private func beginReaction(_ pending: PendingReaction, spent: Bool) {
        switch ContentReactionPolicy.decision(action: pending.action, signedIn: app.isSignedIn, spent: spent) {
        case .signIn: app.showSignIn()
        case .send: sendReaction(pending)
        case .disabled: break
        case .confirm:
            if pending.action == "ChickenLeg" { command.run(app) { allowance = try await app.request("thread.freeChickenLegs"); reaction = pending } }
            else { reaction = pending }
        }
    }
    private var isTracked: Bool { (tracked.value.array ?? []).contains { $0.nativeInt("postId") == postID } }
    private func toggleTracking() {
        guard !title.isEmpty else { return }
        let remove = isTracked
        command.run(app) {
            var arguments = args
            if !remove {
                arguments["title"] = .string(title)
                if let author = thread.value["body"]?.nativeString("authorName") { arguments["authorName"] = .string(author) }
            }
            _ = try await app.request(remove ? "tracked.remove" : "tracked.add", arguments)
            _ = try await app.request("tracked.get")
        }
    }
    private func sendReaction(_ pending: PendingReaction) { command.react(app, postID: postID, commentID: pending.commentID, action: pending.action, page: pending.page, opening: pending.opening) }
    private func edit(_ value: JSONValue, page: Int64, opening: Bool) {
        guard let id = value.nativeInt("commentId") else { return }
        app.open("PostComposer", ["edit": .bool(true), "postId": .integer(postID), "commentId": .integer(id), "isOpeningPost": .bool(opening), "page": .integer(page)])
    }
    private func reply(_ value: JSONValue?, quoting: Bool = false) {
        switch ContentReplyAction.resolve(postID: postID, signedIn: app.isSignedIn, loaded: thread.value != .null, quote: value) {
        case .signIn: app.showSignIn()
        case .unavailable: break
        case .compose(let arguments):
            // No route push: the thread's registered owner retains the editor through dismissal.
            guard departureToken != nil else { return }
            Task { await replyOwner.open(postID: postID, transport: app.transport, generation: app.generation, arguments: arguments, quoting: quoting) }
        }
    }
    private func published(_ result: JSONValue) {
        if let floor = result["floor"]?.int, Int32(exactly: floor) != nil {
            let destination = ContentReadingTarget(floor: "#\(floor)", page: nil).clamped(to: max(totalPages, (floor - 1) / 10 + 1))
            target = destination; targetBottom = false
            load(page: destination.page, extend: destination.page >= firstPage - 1 && destination.page <= lastPage + 1)
        } else { load(page: currentPage, extend: true) }
    }
    private func navigateFromAuthor() {
        guard let navigation = authorNavigation else { return }
        authorNavigation = nil
        switch navigation { case .signIn: app.showSignIn(); case .route(let route, let arguments): app.open(route, arguments) }
    }
    private func openBrowser() {
        guard let current = app.site.nativeString("current"),
              let origin = app.site.nativeArray("sites").first(where: { $0.nativeString("id") == current })?.nativeString("origin"),
              let url = try? FloorShareDocument.sourceURL(origin: origin, postID: postID, page: currentPage, floor: visibleTarget?.floor) else { return }
        app.open("Web", ["url": .string(url.absoluteString)])
    }
    private func updateViewport(_ frames: [String: CGRect], height: CGFloat) {
        if let title = frames["thread.title"] { titleOffscreen = title.maxY < 0 }
        let rows = commentRows
        let visible = rows.filter { frames[$0.id].map { $0.maxY > 0 && $0.minY < height } ?? false }
        if let opening = frames["#0"], opening.maxY > 0, thread.value["body"] != .null, thread.value["body"] != nil {
            visibleTarget = .init(visibleFloor: "#0", page: 1)
            if opening.minY >= 0 { railExpanded = true }
        } else if let row = visible.min(by: { (frames[$0.id]?.minY ?? 0) < (frames[$1.id]?.minY ?? 0) }) {
            visibleTarget = .init(visibleFloor: row.value.nativeString("floor"), page: row.page)
        }
        guard hasRead, target == nil, !loadingPage, lastPage < totalPages,
              let last = visible.last, let index = rows.firstIndex(where: { $0.id == last.id }), index >= max(0, rows.count - 4) else { return }
        load(page: lastPage + 1, extend: true)
    }
    private func restoreScroll(_ proxy: ScrollViewProxy) {
        guard thread.value != .null, let target, !loadingPage else { return }
        if targetBottom {
            guard target.page >= firstPage, target.page <= lastPage else { return }
            proxy.scrollTo("thread.bottom", anchor: .bottom); self.target = nil; targetBottom = false; return
        }
        if let number = target.floor.flatMap(ContentReadingTarget.floorNumber) {
            if number == 0 {
                guard thread.value["body"] != .null, thread.value["body"] != nil else { return }
                proxy.scrollTo("#0", anchor: .top); self.target = nil; return
            }
            if let row = commentRows.first(where: { $0.value.nativeString("floor").flatMap(ContentReadingTarget.floorNumber) == number }) {
                proxy.scrollTo(row.scrollID, anchor: .top); self.target = nil; return
            }
        }
        guard target.page >= firstPage, target.page <= lastPage else { return }
        if let row = commentRows.first(where: { $0.page >= target.page }) {
            proxy.scrollTo(row.scrollID, anchor: .top); self.target = nil
        } else if target.page == 1 { proxy.scrollTo("#0", anchor: .top); self.target = nil }
    }
    private func jump(_ requested: ContentReadingTarget, bottom: Bool = false) {
        let plan = ContentThreadJump(target: requested, thread: thread.value, bottom: bottom)
        hasRead = true; targetBottom = plan.bottom
        // A repeated target must still produce a scroll event.
        target = nil
        if let page = plan.loadPage { load(page: page, extend: plan.extend) }
        target = plan.target
    }
    private func load(page: Int64, extend: Bool) {
        _ = pageLoad.begin()
        loadRequest = PageRequest(page: page, extend: extend)
    }
    @discardableResult
    private func loadPage(_ page: Int64, extend: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        let token = pageLoad.begin()
        let completed = await command.loadThread(app, postID: postID, page: page, extend: extend)
        pageLoad.finish(token, cancelled: Task.isCancelled)
        return completed
    }
    private func openThread() async {
        do {
            let status = try await app.request("thread.status", args)
            let saved = try await app.request("thread.position.get", args)
            try Task.checkCancellation()
            resume = saved.nativeInt("page").map { ContentReadingTarget(visibleFloor: saved.nativeString("floor"), page: $0) }
            let opening = ContentThreadOpening(floor: initialFloor, page: initialPage, status: status)
            firstNewFloor = opening.firstNewFloor; target = opening.target
            if opening.needsLoad { await loadPage(opening.target.page, extend: false) }
            try Task.checkCancellation()
            if command.failure == nil {
                let cached = try await app.request("thread.get", args)
                if cached != .null { _ = try await app.request("thread.markRead", args) }
            }
        } catch is CancellationError { }
        catch { command.failure = contentFailure(error) }
    }
    private struct PendingReaction { let commentID: Int64; let action: String; let page: Int64; let opening: Bool }
}

private func contentFailure(_ error: Error) -> NativeFailure {
    error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
}
