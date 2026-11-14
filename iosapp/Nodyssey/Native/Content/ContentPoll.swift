import SwiftUI
import NodysseyNativeCore

struct ContentPollView: View {
    @EnvironmentObject private var app: NativeAppModel
    let voteID: Int64
    @StateObject private var store = NativeStore()
    @StateObject private var profile = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var selection = ContentPollSelection()
    @State private var retry = 0
    @State private var pending: String?
    @State private var voters: ContentPollItem?
    @State private var deleted = false
    private var items: [ContentIdentityRow] { ContentIdentityRow.rows(store.value.nativeArray("items"), key: "itemId") }
    private var hasVoted: Bool { items.contains { $0.value.nativeBool("voted") == true } }
    private var canMutate: Bool { !command.busy && command.failure == nil && !store.isLoading && store.failure == nil && store.value != .null }
    private var locked: Bool { store.value.nativeBool("locked") == true }
    private var isOwner: Bool {
        guard let owner = store.value.nativeInt("ownerUid"), let uid = profile.value.nativeInt("uid") else { return false }
        return app.isSignedIn && owner == uid
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if deleted { Text(String(localized: "content.pollDeleted", table: "Content")) }
            else {
                ContentStoreStatus(store: store) { retry += 1 }
                ContentCommandStatus(command: command)
                if store.value != .null {
                    Text(store.value.nativeString("title") ?? "").font(.headline)
                    HStack {
                        Text(store.value.nativeBool("multiple") == true ? String(localized: "content.multiple", table: "Content") : String(localized: "content.single", table: "Content"))
                        Text(store.value.nativeBool("isPublic") == true ? String(localized: "content.publicPoll", table: "Content") : String(localized: "content.privatePoll", table: "Content"))
                        if locked { Label(String(localized: "content.locked", table: "Content"), systemImage: "lock") }
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(items) { item in
                        HStack {
                            Button {
                                guard app.isSignedIn else { app.showSignIn(); return }
                                selection.toggle(item.id, multiple: store.value.nativeBool("multiple") == true)
                            } label: {
                                Label(item.value.nativeString("text") ?? "", systemImage: selection.ids.contains(item.id) || item.value.nativeBool("voted") == true ? "checkmark.circle.fill" : "circle")
                            }.disabled(locked || hasVoted || !canMutate)
                            Spacer()
                            if let count = item.value.nativeInt("count") { Text("\(count)") }
                            if store.value.nativeBool("isPublic") == true {
                                Button { voters = ContentPollItem(id: item.id) } label: { Image(systemName: "person.2") }
                                    .accessibilityLabel(Text(String(localized: "content.voters", table: "Content")))
                            }
                        }
                    }
                    if !hasVoted, !locked {
                        Button(String(localized: "content.vote", table: "Content")) {
                            guard app.isSignedIn else { app.showSignIn(); return }
                            pending = "vote.submit"
                        }.disabled(selection.ids.isEmpty || !canMutate)
                    }
                    if isOwner {
                        HStack {
                            Button(locked ? String(localized: "content.unlockPoll", table: "Content") : String(localized: "content.lockPoll", table: "Content")) { pending = "vote.lock" }
                            Button(String(localized: "content.deletePoll", table: "Content"), role: .destructive) { pending = "vote.delete" }
                        }.disabled(!canMutate)
                    }
                    Button(String(localized: "content.refresh", table: "Content")) { retry += 1 }.disabled(command.busy)
                }
            }
        }
        .confirmationDialog(String(localized: "content.pollConfirm", table: "Content"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(String(localized: "content.confirm", table: "Content"), role: pending == "vote.delete" ? .destructive : nil) {
                if let operation = pending { pending = nil; mutate(operation) }
            }
            Button(String(localized: "content.cancel", table: "Content"), role: .cancel) { pending = nil }
        } message: { Text(String(localized: "content.irreversible", table: "Content")) }
        .sheet(item: $voters) { item in NavigationStack { ContentPollVoters(itemID: item.id) } }
        .task(id: "\(app.generation)|\(retry)") {
            selection = ContentPollSelection(); deleted = false
            await store.load(app, "vote.get", ["voteId": .integer(voteID)])
            if store.failure == nil, !Task.isCancelled { command.failure = nil }
        }
        .task(id: app.generation) {
            if app.isSignedIn { await profile.load(app, "profile.self") } else { profile.invalidate() }
        }
        .onChange(of: store.value) { _ in selection.reconcile(allowed: Set(items.map(\.id)), alreadyVoted: hasVoted, locked: locked) }
        .onChange(of: app.generation) { _ in pending = nil; voters = nil; command.cancel() }
        .onDisappear { command.cancel() }
    }
    private func mutate(_ operation: String) {
        guard app.isSignedIn else { app.showSignIn(); return }
        var args: [String: JSONValue] = ["voteId": .integer(voteID)]
        if operation == "vote.submit" { args["itemIds"] = .array(selection.ids.sorted().map(JSONValue.integer)) }
        if operation == "vote.lock" { args["locked"] = .bool(!locked) }
        let arguments = args
        command.run(app) {
            _ = try await app.request(operation, arguments)
            try Task.checkCancellation()
            if operation == "vote.delete" { deleted = true; store.invalidate() }
            else {
                selection = ContentPollSelection()
                // A failed authoritative re-read is displayed separately, never converted into a failed vote/retry.
                await store.load(app, "vote.get", ["voteId": .integer(voteID)])
            }
        }
    }
}

private struct ContentPollItem: Identifiable { let id: Int64 }
private struct ContentPollVoters: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let itemID: Int64
    @StateObject private var store = NativeStore()
    @State private var page: Int64 = 1
    @State private var retry = 0
    private var ids: [Int64] { store.value.array?.compactMap(\.int) ?? [] }
    var body: some View {
        List {
            ContentStoreStatus(store: store) { retry += 1 }
            ForEach(Array(Set(ids)).sorted(), id: \.self) { id in
                Button("\(id)") { dismiss(); app.open("UserSpace", ["uid": .integer(id)]) }
            }
            if store.value.array?.isEmpty == true { NativeEmptyView(String(localized: "content.empty", table: "Content")) }
            HStack {
                Button(String(localized: "content.previous", table: "Content")) { page -= 1 }.disabled(page <= 1 || store.isLoading)
                Text("\(page)")
                Button(String(localized: "content.next", table: "Content")) { page += 1 }.disabled(ids.isEmpty || store.isLoading || store.failure != nil)
            }
        }
        .navigationTitle(Text(String(localized: "content.voters", table: "Content")))
        .toolbar { Button(String(localized: "content.close", table: "Content")) { dismiss() } }
        .task(id: "\(app.generation)|\(page)|\(retry)") { await store.load(app, "vote.voters", ["itemId": .integer(itemID), "page": .integer(page)]) }
    }
}
