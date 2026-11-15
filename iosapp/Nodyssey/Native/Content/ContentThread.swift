import SwiftUI
import NodysseyNativeCore

struct ContentPostDetail: View {
    @EnvironmentObject private var app: NativeAppModel
    let postID: Int64
    let initialFloor: String?
    let initialPage: Int64?
    var preview: JSONValue? = nil
    @State private var showPreview = true
    @StateObject private var thread = NativeStore()
    @StateObject private var tracked = NativeStore()
    @StateObject private var command = ContentThreadCommand()
    @State private var retry = 0
    @State private var loadRetry = 0
    @State private var target: ContentReadingTarget?
    @State private var visibleTarget: ContentReadingTarget?
    @State private var resume: ContentReadingTarget?
    @State private var firstNewFloor: Int64?
    @State private var jumpText = ""
    @State private var floorText = ""
    @State private var loadingPage = false
    @State private var expanded = Set<String>()
    @State private var reaction: PendingReaction?
    @State private var allowance: JSONValue = .null
    private var args: [String: JSONValue] { ["postId": .integer(postID)] }
    private var firstPage: Int64 { thread.value.nativeInt("firstLoadedPage") ?? 1 }
    private var lastPage: Int64 { thread.value.nativeInt("lastLoadedPage") ?? 1 }
    private var totalPages: Int64 { thread.value.nativeInt("totalPages") ?? 1 }
    var body: some View {
        ScrollViewReader { proxy in
            List {
                ContentStoreStatus(store: thread) { retry += 1 }
                ContentCommandStatus(command: command)
                if command.reactionsBlocked {
                    Button(String(localized: "content.reload", table: "Content")) {
                        command.run(app) { await command.reconcileReactions(app, postID: postID) }
                    }
                        .disabled(loadingPage || command.busy)
                }
                if loadingPage { ProgressView() }
                if thread.value == .null, showPreview, let preview { ContentPostRow(value: preview) }
                if thread.value != .null {
                    if let resume {
                        Button(String(localized: "content.resume", table: "Content")) { jump(resume.clamped(to: totalPages)) }
                    }
                    if let body = thread.value["body"], body != .null { floor(body, page: 1, opening: true).id("#0") }
                    else { Text(thread.value.nativeString("title") ?? "").font(.headline).textSelection(.enabled) }
                    Text(String(localized: "content.reply", table: "Content"))
                        .font(.subheadline.weight(.semibold)).listRowSeparator(.hidden)
                    if firstPage > 1 {
                        Button(String(localized: "content.previous", table: "Content")) { load(page: firstPage - 1, extend: true) }.disabled(loadingPage || command.busy)
                    }
                    ForEach(commentRows) { row in
                        let comment = row.value
                        let page = row.page
                        let label = comment.nativeString("floor")
                        VStack(alignment: .leading, spacing: 0) {
                            if let firstNewFloor, label.flatMap(ContentReadingTarget.floorNumber) == firstNewFloor {
                                Label(String(localized: "content.newReplies", table: "Content"), systemImage: "sparkles").foregroundStyle(.tint)
                            }
                            floor(comment, page: page, opening: false)
                        }.id(label ?? row.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden).listRowBackground(ContentThreadCanvas())
                    }
                    if thread.value.nativeBool("hasNextPage") == true || lastPage < totalPages {
                        Button(String(localized: "content.next", table: "Content")) { load(page: lastPage + 1, extend: true) }.disabled(loadingPage || command.busy)
                    }
                    Button(String(localized: "content.refreshTail", table: "Content")) { load(page: lastPage, extend: true) }.disabled(loadingPage || command.busy)
                    Section {
                        HStack { Text("\(firstPage)–\(lastPage) / \(totalPages)"); Spacer() }
                        ContentPageEntry(text: $jumpText) { jump(ContentReadingTarget(floor: nil, page: $0).clamped(to: totalPages)) }
                        HStack {
                            TextField(String(localized: "content.floor", table: "Content"), text: $floorText)
                            Button(String(localized: "content.go", table: "Content")) { jump(ContentReadingTarget(floor: floorText, page: nil).clamped(to: totalPages)) }
                                .disabled(ContentReadingTarget.floorNumber(floorText) == nil)
                        }
                    }
                } else if !thread.isLoading && !loadingPage && thread.failure == nil {
                    NativeEmptyView(String(localized: "content.noCachedThread", table: "Content"))
                    Button(String(localized: "content.reload", table: "Content")) { loadRetry += 1 }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .background(ContentThreadCanvas())
            .onChange(of: thread.value) { value in
                if value != .null { showPreview = false }
                restoreScroll(proxy)
            }
            .onChange(of: target) { _ in restoreScroll(proxy) }
        }
        .navigationTitle(Text(String(localized: "content.thread", table: "Content")))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ContentDirectReplyBar(enabled: thread.value != .null) { reply(nil) }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Destination-scoped preference: the root tab bar returns when this detail is popped.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    guard app.isSignedIn else { app.showSignIn(); return }
                    guard let collected = thread.value.nativeBool("collected") else { return }
                    command.run(app) {
                        _ = try await app.request("thread.collect", ["postId": .integer(postID), "collected": .bool(!collected)])
                        _ = try await app.request("thread.get", args)
                    }
                } label: { Label(String(localized: "content.bookmark", table: "Content"), systemImage: thread.value.nativeBool("collected") == true ? "bookmark.fill" : "bookmark") }
                    .disabled(thread.value.nativeBool("collected") == nil || command.busy)
                Menu {
                    Button(String(localized: "content.track", table: "Content")) { toggleTracking() }
                    Button(String(localized: "content.all", table: "Content")) { app.open("TrackedThreads") }
                } label: { Image(systemName: isTracked ? "bell.fill" : "bell") }
                ContentShareLink(postID: postID, page: visibleTarget?.page ?? firstPage, floor: visibleTarget?.floor)
            }
        }
        .refreshable { await loadPage(firstPage, extend: false) }
        .task(id: "\(app.generation)|\(retry)") { await thread.observe(app, "thread", args) }
        .task(id: "\(app.generation)|\(retry)") { await tracked.observe(app, "tracked.observe") }
        .task(id: "\(app.generation)|\(loadRetry)") { await openThread() }
        .task(id: visibleTarget) {
            guard let position = visibleTarget, thread.value != .null else { return }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                var value = args; value["page"] = .integer(position.page)
                if let floor = position.floor { value["floor"] = .string(floor) }
                _ = try await app.request("thread.position.set", value)
            } catch is CancellationError { }
            catch { command.failure = contentFailure(error) }
        }
        .confirmationDialog(String(localized: "content.reactionConfirm", table: "Content"), isPresented: Binding(get: { reaction != nil }, set: { if !$0 { reaction = nil } })) {
            Button(String(localized: "content.confirm", table: "Content")) { if let reaction { self.reaction = nil; sendReaction(reaction) } }
            Button(String(localized: "content.cancel", table: "Content"), role: .cancel) { reaction = nil }
        } message: {
            if reaction?.action == "Dislike" { Text(String(localized: "content.dislikeCost", table: "Content")) }
            else if let remaining = allowance.nativeInt("remaining"), remaining > 0 { Text(String(localized: "content.freeLegAvailable", table: "Content")) }
            else { Text(String(localized: "content.legCost", table: "Content")) }
        }
        .onChange(of: app.generation) { _ in
            command.cancel(); reaction = nil; allowance = .null; resume = nil; expanded = []; visibleTarget = nil; showPreview = false
        }
        .onDisappear { command.cancel() }
    }
    private struct CommentRow: Identifiable { let id: String; let value: JSONValue; let page: Int64 }
    private var commentRows: [CommentRow] {
        let pages = thread.value.nativeArray("commentPages")
        return thread.value.nativeArray("comments").enumerated().map { index, value in
            // Nullable identities never become server ID zero. Ordinal is only the last-resort display key.
            let id = value.nativeInt("commentId").map { "comment:\($0)" } ?? value.nativeString("floor").map { "floor:\($0)" } ?? "unidentified:\(index)"
            return CommentRow(id: id, value: value, page: pages.indices.contains(index) ? pages[index].int ?? firstPage : firstPage)
        }
    }
    private func restoreScroll(_ proxy: ScrollViewProxy) {
        let value = thread.value
        guard value != .null, let target else { return }
        let comments = value.nativeArray("comments")
        if let number = target.floor.flatMap(ContentReadingTarget.floorNumber) {
            if number == 0 { proxy.scrollTo("#0", anchor: .top); self.target = nil; return }
            if let label = comments.compactMap({ $0.nativeString("floor") }).first(where: { ContentReadingTarget.floorNumber($0) == number }) {
                proxy.scrollTo(label, anchor: .top); self.target = nil; return
            }
        }
        guard !loadingPage, target.page >= firstPage, target.page <= lastPage else { return }
        if let index = value.nativeArray("commentPages").firstIndex(where: { $0.int == target.page }), comments.indices.contains(index), let label = comments[index].nativeString("floor") {
            proxy.scrollTo(label, anchor: .top); self.target = nil
        } else if target.page == 1 { proxy.scrollTo("#0", anchor: .top); self.target = nil }
    }
    @ViewBuilder private func floor(_ value: JSONValue, page: Int64, opening: Bool) -> some View {
        let identity = value.nativeString("floor") ?? (opening ? "#0" : value.nativeInt("commentId").map(String.init) ?? "unknown")
        VStack(alignment: .leading, spacing: 12) {
            if opening {
                // The opening post is an article, not a comment with a title inserted into it.
                VStack(alignment: .leading, spacing: 10) {
                    Text(thread.value.nativeString("title") ?? "")
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                    authorMetadata(value, compact: true)
                }
            } else {
                authorMetadata(value, compact: false)
            }
            if value.nativeBool("isBlocked") == true && !expanded.contains(identity) {
                Button(String(localized: "content.revealBlocked", table: "Content")) { expanded.insert(identity) }
            } else {
                ContentRichBody(value: value["nodes"] ?? .null, postID: postID, threadTitle: thread.value.nativeString("title"), floor: value.nativeString("floor") ?? (opening ? "#0" : nil), jump: { jump(ContentReadingTarget(floor: $0, page: nil)) })
                    .id("\(postID)|\(identity)|body")
                if !value.nativeArray("signatureNodes").isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "content.signature", table: "Content"))
                            .font(.caption).foregroundStyle(.secondary)
                        ContentRichBody(value: value["signatureNodes"] ?? .array([]), postID: postID, threadTitle: thread.value.nativeString("title"), floor: value.nativeString("floor") ?? (opening ? "#0" : nil), role: .signature, jump: { jump(ContentReadingTarget(floor: $0, page: nil)) })
                            .id("\(postID)|\(identity)|signature")
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .top) { VStack(spacing: 0) { Divider(); Spacer(minLength: 0) } }
                }
            }
            Divider().opacity(0.45)
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 16) {
                ContentShareLink(
                    postID: postID,
                    page: page,
                    floor: value.nativeString("floor") ?? (opening ? "#0" : nil),
                    shareContext: FloorShareContext(
                        content: value,
                        threadTitle: thread.value.nativeString("title") ?? "",
                        openingPost: opening,
                        revealedBlocked: expanded.contains(identity)
                    )
                ).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                Button { reply(value) } label: {
                    Label(String(localized: "content.reply", table: "Content"), systemImage: "bubble.right")
                        .labelStyle(.titleAndIcon).frame(minWidth: 44, minHeight: 44)
                }
                if value.nativeBool("isMine") == true, let id = value.nativeInt("commentId") {
                    Button {
                        app.open("PostComposer", ["edit": .bool(true), "postId": .integer(postID), "commentId": .integer(id), "isOpeningPost": .bool(opening), "page": .integer(page)])
                    } label: {
                        Label(String(localized: "content.edit", table: "Content"), systemImage: "square.and.pencil")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let id = value.nativeInt("commentId") {
                    reactionButton("Upvote", field: "upvoted", count: "upvoteCount", symbol: "hand.thumbsup", value: value, commentID: id, page: page, opening: opening)
                    reactionButton("ChickenLeg", field: "liked", count: "likeCount", symbol: "gift", value: value, commentID: id, page: page, opening: opening)
                    reactionButton("Dislike", field: "disliked", count: "dislikeCount", symbol: "hand.thumbsdown", value: value, commentID: id, page: page, opening: opening)
                }
              }.font(.subheadline).foregroundStyle(.secondary)
            }.buttonStyle(.borderless).disabled(command.busy || loadingPage)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading).background(ContentSurface())
        .padding(.bottom, 8).background(ContentThreadCanvas())
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden).listRowBackground(ContentThreadCanvas())
        .onAppear { visibleTarget = ContentReadingTarget(floor: value.nativeString("floor"), page: page) }
    }
    private func authorMetadata(_ value: JSONValue, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let uid = value.nativeInt("authorUid") { app.open("UserSpace", ["uid": .integer(uid)]) }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    ContentAvatar(value: value, size: compact ? 28 : 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(value.nativeString("authorName") ?? "")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let time = value.nativeString("createdAtText") {
                            Text(time).font(.caption).foregroundStyle(.secondary)
                        }
                        if value.nativeBool("isEdited") == true {
                            Text(String(localized: "content.edited", table: "Content") + " " + (value.nativeString("editedAtText") ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(value.nativeInt("authorUid") == nil)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let label = value.nativeString("floor") { Text(label) }
                if value.nativeBool("isOriginalPoster") == true {
                    Text(String(localized: "content.originalPoster", table: "Content"))
                }
                // Keep other server badges, without repeating the localized OP label.
                let badges = value.nativeArray("badges").compactMap(\.string).filter {
                    value.nativeBool("isOriginalPoster") != true || $0 != String(localized: "content.originalPoster", table: "Content")
                }
                if !badges.isEmpty { Text(badges.joined(separator: " · ")) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func reactionButton(_ action: String, field: String, count: String, symbol: String, value: JSONValue, commentID: Int64, page: Int64, opening: Bool) -> some View {
        let spent = value["reactions"]?.nativeBool(field) == true
        return Button {
            let pending = PendingReaction(commentID: commentID, action: action, page: page, opening: opening)
            switch ContentReactionPolicy.decision(action: action, signedIn: app.isSignedIn, spent: spent) {
            case .signIn: app.showSignIn()
            case .send: sendReaction(pending)
            case .disabled: break
            case .confirm:
                if action == "ChickenLeg" {
                    command.run(app) { allowance = try await app.request("thread.freeChickenLegs"); reaction = pending }
                } else { reaction = pending }
            }
        } label: {
            Label(value["reactions"]?.nativeInt(count).map(String.init) ?? "—", systemImage: spent ? symbol + ".fill" : symbol)
                .foregroundStyle(spent ? Color.primary : Color.secondary)
                .frame(minWidth: 44, minHeight: 44)
        }.disabled(spent || command.reactionsBlocked)
        .accessibilityValue(Text(value["reactions"]?.nativeInt(count).map(String.init) ?? "—"))
        .accessibilityLabel(Text(action == "Upvote" ? String(localized: "content.Upvote", table: "Content") : action == "ChickenLeg" ? String(localized: "content.ChickenLeg", table: "Content") : String(localized: "content.Dislike", table: "Content")))
    }
    private var isTracked: Bool { (tracked.value.array ?? []).contains { $0.nativeInt("postId") == postID } }
    private func toggleTracking() {
        guard let title = thread.value.nativeString("title") else { return }
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
    private func sendReaction(_ pending: PendingReaction) {
        command.react(app, postID: postID, commentID: pending.commentID, action: pending.action, page: pending.page, opening: pending.opening)
    }
    private func reply(_ value: JSONValue?) {
        switch ContentReplyAction.resolve(postID: postID, signedIn: app.isSignedIn, loaded: thread.value != .null, quote: value) {
        case .signIn: app.showSignIn()
        case .unavailable: break
        case .compose(let arguments): app.open("PostComposer", arguments)
        }
    }
    private func jump(_ target: ContentReadingTarget) {
        self.target = target
        load(page: target.page, extend: false)
    }
    private func load(page: Int64, extend: Bool) {
        command.run(app) { await loadPage(page, extend: extend) }
    }
    private func loadPage(_ page: Int64, extend: Bool) async {
        guard !loadingPage else { return }
        loadingPage = true; defer { loadingPage = false }
        await command.loadThread(app, postID: postID, page: page, extend: extend)
    }
    private func openThread() async {
        do {
            // Must precede markRead; otherwise the unread baseline vanishes.
            let status = try await app.request("thread.status", args)
            let saved = try await app.request("thread.position.get", args)
            try Task.checkCancellation()
            resume = saved.nativeInt("page").map { ContentReadingTarget(floor: saved.nativeString("floor"), page: $0) }
            let opening = ContentThreadOpening(floor: initialFloor, page: initialPage, status: status)
            firstNewFloor = opening.firstNewFloor
            target = opening.target
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

/// Subtle cool-neutral section gaps without replacing the reader's selected accent.
private struct ContentThreadCanvas: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        scheme == .dark
            ? Color(red: 0.045, green: 0.055, blue: 0.065)
            : Color(red: 0.925, green: 0.94, blue: 0.955)
    }
}

/// An editor entry, not a text field or send button. The system owns keyboard/tab safe areas.
struct ContentDirectReplyBar: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let enabled: Bool
    var reply: () -> Void

    var body: some View {
        Button(action: reply) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").foregroundStyle(.tint)
                Text(String(localized: "content.writeComment", table: "Content"))
                Spacer(minLength: 0)
            }
            .font(.body).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled)
        .background(reduceTransparency || contrast == .increased
            ? AnyShapeStyle(.background)
            : AnyShapeStyle(.regularMaterial))
    }
}
