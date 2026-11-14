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
                        Text(String(localized: "content.interactions", table: "Content")).tag("INTERACTIONS")
                        Text(String(localized: "content.messages", table: "Content")).tag("MESSAGES")
                    }.pickerStyle(.segmented).padding(.horizontal)
                    List {
                        ContentCommandStatus(command: command)
                        ContentStoreStatus(store: counts) { retry += 1 }
                        if let count = counts.value.nativeInt(selection == "MESSAGES" ? "messages" : "interactions") {
                            Label("\(count)", systemImage: "envelope.badge")
                        }
                        if selection == "MESSAGES" {
                            ContentStoreStatus(store: messages) { retry += 1 }
                            ForEach(ContentIdentityRow.rows(messages.value.array ?? [], key: "uid")) { row in
                                Button { app.open("MessageThread", ["uid": .integer(row.id)]) } label: { conversation(row.value) }
                            }
                            if messages.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
                        } else {
                            ContentStoreStatus(store: interactions) { retry += 1 }
                            ForEach(notificationGroups) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        Button { openNotification(row.value) } label: { notification(row.value) }
                                            .disabled(command.busy)
                                    }
                                } header: { Text(group.title) }
                            }
                            if interactions.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
                        }
                    }.refreshable { await refresh() }
                }
            }
        }
        .navigationTitle(Text(String(localized: "content.notifications", table: "Content")))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(String(localized: "content.readAll", table: "Content")) { confirmReadAll = true }.disabled(!app.isSignedIn || command.busy)
                Button { compose = true } label: { Label(String(localized: "content.newMessage", table: "Content"), systemImage: "square.and.pencil") }.disabled(!app.isSignedIn)
            }
        }
        .confirmationDialog(String(localized: "content.readAll", table: "Content"), isPresented: $confirmReadAll) {
            Button(String(localized: "content.confirm", table: "Content")) { readAll() }
            Button(String(localized: "content.cancel", table: "Content"), role: .cancel) { }
        }
        .sheet(isPresented: $compose) { NavigationStack { ContentNewConversation() } }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { interactions.invalidate(); return }
            await interactions.observe(app, "notifications.list")
        }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { messages.invalidate(); return }
            await messages.observe(app, "messages.list")
        }
        .task(id: "\(app.generation)|\(retry)") {
            guard app.isSignedIn else { counts.invalidate(); return }
            await counts.observe(app, "notifications.counts")
        }
        .onDisappear { command.cancel() }
    }
    private struct Row: Identifiable { let id: String; let value: JSONValue }
    private var notificationRows: [Row] {
        (interactions.value.array ?? []).compactMap { value in
            guard let id = value.nativeString("id") else { return nil }; return Row(id: id, value: value)
        }
    }
    private struct NotificationGroup: Identifiable { var id: String { title }; let title: String; var rows: [Row] }
    private var notificationGroups: [NotificationGroup] {
        var groups: [NotificationGroup] = []
        for row in notificationRows {
            let title = row.value.nativeInt("createdAtMillis").map {
                Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .omitted)
            } ?? row.value.nativeString("createdAtText") ?? ""
            if let index = groups.firstIndex(where: { $0.title == title }) { groups[index].rows.append(row) }
            else { groups.append(NotificationGroup(title: title, rows: [row])) }
        }
        return groups
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
        command.run(app) {
            if selection == "MESSAGES" { _ = try await app.request("messages.readAll") }
            else {
                // Deliberately two independent acknowledgements, never MESSAGES or synthetic merged IDs.
                _ = try await app.request("notifications.readAll", ["category": .string("REPLIES")])
                _ = try await app.request("notifications.readAll", ["category": .string("MENTIONS")])
            }
            _ = try await app.request("notifications.counts")
        }
    }
    private func refresh() async {
        do {
            if selection == "MESSAGES" { _ = try await app.request("messages.refresh") }
            else { _ = try await app.request("notifications.refresh") }
        } catch is CancellationError { }
        catch { command.failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.") }
    }
    private func notification(_ value: JSONValue) -> some View {
        HStack(alignment: .top) {
            ContentAvatar(value: value)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(value.nativeString("actorName") ?? "").font(.headline)
                    if value.nativeBool("isReply") == true { Image(systemName: "arrowshape.turn.up.left") }
                    if value.nativeBool("isMention") == true { Image(systemName: "at") }
                    if value.nativeBool("isUnread") == true { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.tint) }
                }
                if let title = value.nativeString("threadTitle") { Text(title) }
                HStack {
                    if let floor = value.nativeString("floor") { Text(floor) }
                    if let date = value.nativeString("createdAtText") { Text(date) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func conversation(_ value: JSONValue) -> some View {
        HStack {
            ContentAvatar(value: value)
            VStack(alignment: .leading) {
                Text(value.nativeString("userName") ?? "").font(.headline)
                Text(value.nativeArray("snippet").map { part in
                    part.nativeString("text") ?? "[\(part.nativeString("kind") ?? "")]"
                }.joined()).lineLimit(2)
                if let date = value.nativeString("updatedAtText") { Text(date).font(.caption).foregroundStyle(.secondary) }
            }
            if let unread = value.nativeInt("unreadCount"), unread > 0 { Text("\(unread)").foregroundStyle(.tint) }
        }
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
                    app.open("MessageThread", ["uid": .integer(row.id)])
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
