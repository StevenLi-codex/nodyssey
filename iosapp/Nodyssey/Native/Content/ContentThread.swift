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
    @StateObject private var command = ContentCommand()
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
                if loadingPage { ProgressView() }
                if thread.value == .null, showPreview, let preview { ContentPostRow(value: preview) }
                if thread.value != .null {
                    if let resume {
                        Button(String(localized: "content.resume", table: "Content")) { jump(resume.clamped(to: totalPages)) }
                    }
                    Section {
                        Text(thread.value.nativeString("title") ?? "").font(.title2).textSelection(.enabled)
                        if let body = thread.value["body"], body != .null { floor(body, page: 1, opening: true).id("#0") }
                    }
                    if firstPage > 1 {
                        Button(String(localized: "content.previous", table: "Content")) { load(page: firstPage - 1, extend: true) }.disabled(loadingPage || command.busy)
                    }
                    ForEach(commentRows) { row in
                        let comment = row.value
                        let page = row.page
                        let label = comment.nativeString("floor")
                        Section {
                            if let firstNewFloor, label.flatMap(ContentReadingTarget.floorNumber) == firstNewFloor {
                                Label(String(localized: "content.newReplies", table: "Content"), systemImage: "sparkles").foregroundStyle(.tint)
                            }
                            floor(comment, page: page, opening: false)
                        }.id(label ?? row.id)
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
            .onChange(of: thread.value) { value in
                if value != .null { showPreview = false }
                restoreScroll(proxy)
            }
            .onChange(of: target) { _ in restoreScroll(proxy) }
        }
        .navigationTitle(Text(String(localized: "content.thread", table: "Content")))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { reply(nil) } label: { Label(String(localized: "content.reply", table: "Content"), systemImage: "arrowshape.turn.up.left") }
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
            HStack {
                ContentAvatar(value: value)
                Button(value.nativeString("authorName") ?? "") {
                    if let uid = value.nativeInt("authorUid") { app.open("UserSpace", ["uid": .integer(uid)]) }
                }.disabled(value.nativeInt("authorUid") == nil)
                if value.nativeBool("isOriginalPoster") == true { Text(String(localized: "content.originalPoster", table: "Content")).font(.caption) }
                Spacer()
                if let label = value.nativeString("floor") { Text(label).foregroundStyle(.secondary) }
            }
            if !value.nativeArray("badges").isEmpty {
                Text(value.nativeArray("badges").compactMap(\.string).joined(separator: " · ")).font(.caption)
            }
            HStack {
                if let time = value.nativeString("createdAtText") { Text(time) }
                if value.nativeBool("isEdited") == true { Text(String(localized: "content.edited", table: "Content")); Text(value.nativeString("editedAtText") ?? "") }
            }.font(.caption).foregroundStyle(.secondary)
            if value.nativeBool("isBlocked") == true && !expanded.contains(identity) {
                Button(String(localized: "content.revealBlocked", table: "Content")) { expanded.insert(identity) }
            } else {
                ContentRichBody(value: value["nodes"] ?? .null, postID: postID, threadTitle: thread.value.nativeString("title"), floor: value.nativeString("floor") ?? (opening ? "#0" : nil), jump: { jump(ContentReadingTarget(floor: $0, page: nil)) })
                    .id("\(postID)|\(identity)|body")
                if !value.nativeArray("signatureNodes").isEmpty {
                    Divider()
                    ContentRichBody(value: value["signatureNodes"] ?? .array([]), postID: postID, threadTitle: thread.value.nativeString("title"), floor: value.nativeString("floor") ?? (opening ? "#0" : nil), jump: { jump(ContentReadingTarget(floor: $0, page: nil)) })
                        .font(.footnote).id("\(postID)|\(identity)|signature")
                }
            }
            HStack {
                Button(String(localized: "content.reply", table: "Content")) { reply(value) }
                if value.nativeBool("isMine") == true, let id = value.nativeInt("commentId") {
                    Button(String(localized: "content.edit", table: "Content")) {
                        app.open("PostComposer", ["edit": .bool(true), "postId": .integer(postID), "commentId": .integer(id), "isOpeningPost": .bool(opening), "page": .integer(page)])
                    }
                }
                if let id = value.nativeInt("commentId") {
                    reactionButton("Upvote", field: "upvoted", count: "upvoteCount", symbol: "hand.thumbsup", value: value, commentID: id)
                    reactionButton("ChickenLeg", field: "liked", count: "likeCount", symbol: "gift", value: value, commentID: id)
                    reactionButton("Dislike", field: "disliked", count: "dislikeCount", symbol: "hand.thumbsdown", value: value, commentID: id)
                }
            }.buttonStyle(.borderless).disabled(command.busy || command.failure != nil || loadingPage)
        }
        .onAppear { visibleTarget = ContentReadingTarget(floor: value.nativeString("floor"), page: page) }
    }
    private func reactionButton(_ action: String, field: String, count: String, symbol: String, value: JSONValue, commentID: Int64) -> some View {
        let spent = value["reactions"]?.nativeBool(field) == true
        return Button {
            let pending = PendingReaction(commentID: commentID, action: action)
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
        }.disabled(spent).accessibilityLabel(Text(action == "Upvote" ? String(localized: "content.Upvote", table: "Content") : action == "ChickenLeg" ? String(localized: "content.ChickenLeg", table: "Content") : String(localized: "content.Dislike", table: "Content")))
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
        command.run(app) {
            _ = try await app.request("thread.react", ["postId": .integer(postID), "commentId": .integer(pending.commentID), "action": .string(pending.action)])
            _ = try await app.request("thread.config", args)
        }
    }
    private func reply(_ value: JSONValue?) {
        guard app.isSignedIn else { app.showSignIn(); return }
        var arguments = args; arguments["reply"] = .bool(true)
        if let floor = value?.nativeString("floor").flatMap(ContentReadingTarget.floorNumber) { arguments["quotedFloor"] = .integer(floor) }
        if let author = value?.nativeString("authorName") { arguments["replyToAuthor"] = .string(author) }
        if let nodes = value?["nodes"] { arguments["replyToText"] = .string(ContentQuoteContext.text(nodes)) }
        app.open("PostComposer", arguments)
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
        do { _ = try await app.request("thread.load", ["postId": .integer(postID), "page": .integer(page), "extend": .bool(extend)]); command.failure = nil }
        catch is CancellationError { }
        catch { command.failure = contentFailure(error) }
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
    private struct PendingReaction { let commentID: Int64; let action: String }
}

private func contentFailure(_ error: Error) -> NativeFailure {
    error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
}
