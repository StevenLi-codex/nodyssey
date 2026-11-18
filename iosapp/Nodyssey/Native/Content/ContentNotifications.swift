import SwiftUI
import NodysseyNativeCore

struct ContentNotifications: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var interactions = NativeStore()
    @StateObject private var messages = NativeStore()
    @StateObject private var counts = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var selection = "INTERACTIONS"
    @State private var retry = 0
    @StateObject private var refreshState = ContentNotificationRefresh()
    @State private var compose = false
    @State private var confirmReadAll = false
    init(initialGroup: String? = nil) {
        _selection = State(initialValue: initialGroup == "messages" ? "MESSAGES" : "INTERACTIONS")
    }
    var body: some View {
        Group {
            if !app.isSignedIn {
                Button(String(localized: "content.signIn", table: "Content")) { app.showSignIn() }
            } else {
                VStack {
                    Picker(String(localized: "content.notifications", table: "Content"), selection: $selection) {
                        Text(groupLabel("interactions")).tag("INTERACTIONS")
                        Text(groupLabel("messages")).tag("MESSAGES")
                    }.pickerStyle(.segmented).padding(.horizontal)
                    List {
                        ContentCommandStatus(command: command)
                        if let failure = counts.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
                        if selection == "MESSAGES" {
                            ContentStoreStatus(store: messages, initialLoading: true, silentRefresh: true) { retry += 1 }
                            ForEach(conversations(system: true)) { row in conversationButton(row) }
                            if !conversations(system: true).isEmpty, !conversations(system: false).isEmpty {
                                Section { ForEach(conversations(system: false)) { row in conversationButton(row) } }
                                header: { Text("messages_section_all") }
                            } else { ForEach(conversations(system: false)) { row in conversationButton(row) } }
                            if messages.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
                        } else {
                            ContentStoreStatus(store: interactions, initialLoading: true, silentRefresh: true) { retry += 1 }
                            ForEach(notificationGroups) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        Button { openNotification(row.value) } label: { ContentNotificationRow(value: row.value) }
                                            .buttonStyle(.plain)
                                            .disabled(command.busy)
                                    }
                                } header: { Text(LocalizedStringKey(group.id)) }
                            }
                            if interactions.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(ContentSurface(canvas: true))
                    .nativeRefreshable(generation: app.generation,
                        failure: { refreshState.group == "MESSAGES" ? messages.failure != nil : interactions.failure != nil },
                        completion: { refreshState.succeeded }) { await refresh() }
                }
            }
        }
        .nativePageCanvas()
        .navigationTitle(Text(String(localized: "content.notifications", table: "Content")))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(String(localized: "content.readAll", table: "Content")) { confirmReadAll = true }.disabled(!app.isSignedIn || command.busy || selectedUnread == 0)
                if selection == "MESSAGES" {
                    Button { compose = true } label: { Label(String(localized: "content.newMessage", table: "Content"), systemImage: "square.and.pencil") }.disabled(!app.isSignedIn)
                }
            }
        }
        .confirmationDialog(String(localized: "content.readAll", table: "Content"), isPresented: $confirmReadAll) {
            Button(String(localized: "content.confirm", table: "Content")) { readAll() }
            Button(String(localized: "content.cancel", table: "Content"), role: .cancel) { }
        }
        .sheet(isPresented: $compose) { NavigationStack { ContentNewConversation() } }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { interactions.invalidate(); return }
            interactions.observeRetained(app, "notifications.list", restart: retry)
        }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { messages.invalidate(); return }
            messages.observeRetained(app, "messages.list", restart: retry)
        }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { counts.invalidate(); return }
            counts.observeRetained(app, "notifications.counts", restart: retry)
        }
        .onChange(of: selection) { _ in refreshState.invalidate() }
        .onDisappear { command.cancel(); refreshState.invalidate() }
    }
    private struct Row: Identifiable { let id: String; let value: JSONValue }
    private var notificationRows: [Row] {
        (interactions.value.array ?? []).compactMap { value in
            guard let id = value.nativeString("id") else { return nil }; return Row(id: id, value: value)
        }
    }
    private var selectedUnread: Int64 { max(0, counts.value.nativeInt(selection == "MESSAGES" ? "messages" : "interactions") ?? 0) }
    private func groupLabel(_ key: String) -> String {
        let title = NSLocalizedString("content." + key, tableName: "Content", comment: "")
        let count = max(0, counts.value.nativeInt(key) ?? 0)
        return count > 0 ? "\(title) (\(count))" : title
    }
    private func conversations(system: Bool) -> [ContentIdentityRow] {
        ContentIdentityRow.rows(messages.value.array ?? [], key: "uid").filter { ($0.value.nativeBool("isSystem") == true) == system }
    }
    private func conversationButton(_ row: ContentIdentityRow) -> some View {
        Button { app.open("MessageThread", ["uid": .integer(row.id), "userName": .string(row.value.nativeString("userName") ?? "")]) }
        label: { ContentConversationRow(value: row.value) }.buttonStyle(.plain)
    }
    private struct NotificationGroup: Identifiable { let id: String; var rows: [Row] }
    private var notificationGroups: [NotificationGroup] {
        let now = Date()
        let grouped = Dictionary(grouping: notificationRows) { contentNotificationDay($0.value.nativeInt("createdAtMillis"), now: now) }
        return ["today", "yesterday", "week", "earlier"].compactMap { day in
            guard let rows = grouped[day] else { return nil }
            return NotificationGroup(id: "history_section_" + day, rows: rows)
        }
    }
    private func openNotification(_ row: JSONValue) {
        command.run(app) {
            let args = try ContentNotificationAction.readArguments(row)
            _ = try await app.request("notifications.read", args)
            try Task.checkCancellation()
            if let post = row.nativeInt("postId"), post > 0 {
                var target: [String: JSONValue] = ["postId": .integer(post)]
                if let floor = row.nativeString("floor") { target["floor"] = .string(floor) }
                app.open("PostDetail", target)
            } else if let uid = row.nativeInt("actorUid"), uid > 0 {
                app.open("UserSpace", ["uid": .integer(uid)])
            }
        }
    }
    private func readAll() {
        guard selectedUnread > 0 else { return }
        let group = selection
        command.run(app) {
            if group == "MESSAGES" { _ = try await app.request("messages.readAll") }
            else {
                // Deliberately two independent acknowledgements, never MESSAGES or synthetic merged IDs.
                _ = try await app.request("notifications.readAll", ["category": .string("REPLIES")])
                _ = try await app.request("notifications.readAll", ["category": .string("MENTIONS")])
            }
            _ = try await app.request("notifications.counts")
        }
    }
    private func refresh() async {
        refreshState.invalidate()
        guard app.isSignedIn, !Task.isCancelled else { return }
        let group = selection
        let store = group == "MESSAGES" ? messages : interactions
        await refreshState.perform(app, group: group) {
            await store.refreshRetained(app,
                group == "MESSAGES" ? "messages.refresh" : "notifications.refresh", mode: .revision)
        }
    }
}

/// Match Android's calendar buckets (future = today, unknown = earlier).
func contentNotificationDay(_ millis: Int64?, now: Date = Date(), calendar: Calendar = .current) -> String {
    guard let millis else { return "earlier" }
    let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(millis) / 1000))
    let today = calendar.startOfDay(for: now)
    let distance = calendar.dateComponents([.day], from: day, to: today).day ?? 7
    switch distance {
    case ...0: return "today"
    case 1: return "yesterday"
    case 2...6: return "week"
    default: return "earlier"
    }
}

struct ContentNotificationRow: View {
    let value: JSONValue
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ContentAvatar(value: value, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(sentence).font(.subheadline).lineLimit(nil)
                    .foregroundStyle(value.nativeBool("isUnread") == true ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = value.nativeString("createdAtText") { Text(date).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                .opacity(value.nativeBool("isUnread") == true ? 1 : 0).padding(.top, 7)
                .accessibilityHidden(true)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private var sentence: AttributedString {
        let reply = value.nativeBool("isReply") == true
        let mention = value.nativeBool("isMention") == true
        let key = reply ? (mention ? "notification_sentence_reply_mention" : "notification_sentence_reply") : "notification_sentence_mention"
        let template = NSLocalizedString(key, comment: "")
        // Replace template tokens as runs, never search for user text after formatting.
        var result = AttributedString()
        var remaining = template[...]
        while let range = remaining.range(of: "%[12]\\$@", options: .regularExpression) {
            result += AttributedString(String(remaining[..<range.lowerBound]))
            let actor = remaining[range] == "%1$@"
            var part = AttributedString(actor ? (value.nativeString("actorName") ?? "") : (value.nativeString("threadTitle") ?? NSLocalizedString("notification_unknown_thread", comment: "")))
            part.font = .subheadline.weight(.semibold)
            if !actor, value.nativeBool("isUnread") == true { part.foregroundColor = .accentColor }
            result += part
            remaining = remaining[range.upperBound...]
        }
        result += AttributedString(String(remaining))
        return result
    }
}

struct ContentConversationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let value: JSONValue
    var body: some View {
        let unread = max(0, value.nativeInt("unreadCount") ?? 0)
        HStack(alignment: .top, spacing: 10) {
            if value.nativeBool("isSystem") == true {
                Image(systemName: "megaphone.fill").foregroundStyle(.tint)
                    .frame(width: 40, height: 40).background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else { ContentAvatar(value: value) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value.nativeString("userName") ?? "").font(.subheadline.weight(unread > 0 ? .semibold : .medium))
                    if value.nativeBool("isSystem") == true { Image(systemName: "pin.fill").font(.caption).accessibilityLabel(Text("messages_pinned")) }
                    Spacer(minLength: 0)
                    if let date = value.nativeString("updatedAtText") { Text(date).font(.caption).foregroundStyle(unread > 0 ? Color.accentColor : Color.secondary) }
                }
                HStack(alignment: .top) {
                    Text(snippet).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    if unread > 0 { Text("\(unread)").font(.caption.weight(.semibold)).foregroundStyle(.tint) }
                }
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
    }
    private var snippet: String {
        let keys = ["IMAGE": "image", "STICKER": "sticker", "CODE": "code", "TABLE": "table", "VOTE": "vote", "PAYMENT": "payment"]
        let body = value.nativeArray("snippet").map { part in
            if part.nativeString("type") == "Text" { return part.nativeString("text") ?? "" }
            guard let kind = part.nativeString("kind"), let suffix = keys[kind] else { return "" }
            return NSLocalizedString("notification_preview_" + suffix, comment: "")
        }.joined()
        return (value.nativeBool("isSnippetMine") == true ? NSLocalizedString("messages_snippet_mine_prefix", comment: "") : "") + body
    }
}

private struct ContentNewConversation: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = NativeStore()
    @State private var query = ""
    @State private var submitted = ""
    @State private var retry = 0
    var body: some View {
        List {
            ContentStoreStatus(store: store) { retry += 1 }
            ForEach(ContentIdentityRow.rows(store.value.array ?? [], key: "uid")) { row in
                Button {
                    dismiss()
                    app.open("MessageThread", ["uid": .integer(row.id), "userName": .string(row.value.nativeString("name") ?? "")])
                } label: { HStack { ContentAvatar(value: row.value); Text(row.value.nativeString("name") ?? "") } }
            }
            if store.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
        }
        .navigationTitle(Text(String(localized: "content.newMessage", table: "Content")))
        .searchable(text: $query)
        .onSubmit(of: .search) { submitted = query; retry += 1 }
        .toolbar { Button(String(localized: "content.close", table: "Content")) { dismiss() } }
        .task(id: "\(app.generation)|\(submitted)|\(retry)") {
            store.invalidate()
            guard !submitted.isEmpty else { return }
            await store.load(app, "search.users", ["query": .string(submitted)])
        }
    }
}
