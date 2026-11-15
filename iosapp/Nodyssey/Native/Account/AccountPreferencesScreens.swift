import SwiftUI
import NodysseyNativeCore

struct AccountPreferencesScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var pending: AccountPendingWrite?
    var body: some View {
        Form {
            if app.isSignedIn {
                AccountStoreStatus(store: store) { reload() }
                if let holiday = store.value.nativeBool("holidayTheme") {
                    Section("account_group_preference") {
                        Toggle("account_holiday_theme", isOn: Binding(get: { holiday }, set: {
                            pending = AccountPendingWrite("account.holidayTheme", ["enabled": .bool($0)])
                        })).disabled(action.blocked)
                        Text("account_holiday_theme_hint").font(.caption)
                    }
                }
                if store.value["hiddenBoards"]?.array != nil {
                    Section("account_group_homepage") {
                        board("trade", "account_board_trade")
                        board("life", "account_board_life")
                        board("photo-share", "account_board_photo")
                        Text("account_home_boards_hint").font(.caption)
                    }
                }
                Text("account_preferences_omitted_note").font(.caption)
                AccountActionStatus(action: action)
            } else { AccountRequireSignIn() }
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("account_preferences_title")
        .task(id: app.generation) { action.cancel(); pending = nil; await store.load(app, "account.preferences") }
        .confirmationDialog("account_action_save", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("account_action_save") {
                guard let write = pending else { return }; pending = nil
                action.perform(app, operation: write.operation, arguments: write.arguments, read: {
                    store.value = try await app.request("account.preferences")
                })
            }
        }
        .onDisappear { action.cancel() }
    }
    private func board(_ slug: String, _ title: String) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(get: {
            !store.value.nativeArray("hiddenBoards").contains(.string(slug))
        }, set: { pending = AccountPendingWrite("account.homeBoard", ["slug": .string(slug), "hidden": .bool(!$0)]) })).disabled(action.blocked)
    }
    private func reload() { Task { await store.load(app, "account.preferences") } }
}

struct AccountBlockScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var users = NativeStore()
    @StateObject private var keywords = NativeStore()
    @StateObject private var settings = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var titles: Bool
    @StateObject private var draft = AccountKeywordDraft()
    @State private var name = ""
    @State private var query = ""
    @State private var pending: AccountPendingWrite?
    init(titles: Bool) { _titles = State(initialValue: titles) }
    private var kind: String { draft.kind }
    var body: some View {
        Form {
            Picker("block_title", selection: $titles) {
                Text("block_tab_users").tag(false); Text("block_tab_titles").tag(true)
            }.pickerStyle(.segmented)
            if let show = settings.value.nativeBool("showBlockedContent") {
                Toggle("account_block_show_temporarily", isOn: Binding(get: { show }, set: {
                    pending = AccountPendingWrite("settings.set", ["key": .string("showBlockedContent"), "value": .bool($0)])
                })).disabled(action.blocked)
            }
            if titles {
                Toggle("keywords_regex_toggle", isOn: $draft.regex)
                TextField(LocalizedStringKey(draft.regex ? "keywords_regex_placeholder" : "keywords_add_placeholder"), text: $draft.text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("keywords_add_action") { pending = draft.add() }
                    .disabled(action.blocked || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                AccountStoreStatus(store: keywords) { reloadKeywords() }
                let rules = (keywords.value.array ?? []).compactMap(\.string).filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
                if rules.isEmpty && !keywords.isLoading && keywords.failure == nil {
                    Text(query.isEmpty ? "native.account.empty_rules" : "native.account.no_matches", tableName: "Account")
                }
                ForEach(rules, id: \.self) { rule in
                    HStack {
                        Text(rule).textSelection(.enabled)
                        Spacer()
                        Button("action_delete", role: .destructive) {
                            pending = AccountPendingWrite("keywords.remove", ["kind": .string(kind), "text": .string(rule)])
                        }.disabled(action.blocked)
                    }
                }
                Text("block_titles_footer").font(.caption)
            } else if app.isSignedIn {
                TextField("account_block_add_placeholder", text: $name).textInputAutocapitalization(.never)
                Button("account_block_add_action") { pending = AccountPendingWrite("social.block", ["name": .string(name), "confirmed": .bool(true)]) }
                    .disabled(action.blocked || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                AccountStoreStatus(store: users) { Task { await users.load(app, "account.blockedUsers") } }
                let rows = AccountUserRow.rows(users.value, query: query)
                if rows.isEmpty && !users.isLoading && users.failure == nil {
                    Text(query.isEmpty ? "native.account.empty_blocked" : "native.account.no_matches", tableName: "Account")
                }
                ForEach(rows) { user in
                    HStack {
                        Button(user.name) { app.open("UserSpace", ["uid": .integer(user.id)]) }
                        Spacer()
                        Button("account_block_unblock", role: .destructive) {
                            pending = AccountPendingWrite("social.unblock", ["uid": .integer(user.id), "confirmed": .bool(true)])
                        }.disabled(action.blocked)
                    }
                }
                Text("account_block_footer").font(.caption)
            } else { AccountRequireSignIn() }
            AccountActionStatus(action: action)
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("block_title")
        .searchable(text: $query)
        .task(id: app.generation) {
            action.cancel(); pending = nil; name = ""; draft.text = ""
            await settings.load(app, "settings.get")
            if app.isSignedIn { await users.load(app, "account.blockedUsers") }
        }
        .task(id: kind + String(app.generation)) { await keywords.load(app, "keywords.get", ["kind": .string(kind)]) }
        .confirmationDialog("account_action_save", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("action_done", role: .destructive) {
                guard let write = pending else { return }; pending = nil
                if write.operation.hasPrefix("keywords.") {
                    draft.perform(write, action: action, request: { try await app.request($0, $1) },
                                  currentGeneration: { app.generation }, publish: { keywords.value = $0 })
                    return
                }
                action.perform(app, operation: write.operation, arguments: write.arguments, read: {
                    if write.operation.hasPrefix("social.") { users.value = try await app.request("account.blockedUsers"); name = "" }
                    else { settings.value = try await app.request("settings.get") }
                })
            }
        }
        .onDisappear { action.cancel() }
    }
    private func reloadKeywords() { Task { await keywords.load(app, "keywords.get", ["kind": .string(kind)]) } }
}

struct AccountUserRow: Identifiable {
    let id: Int64
    let name: String
    let avatar: String?
    static func rows(_ value: JSONValue, query: String) -> [AccountUserRow] {
        var seen = Set<Int64>()
        return (value.array ?? []).compactMap { value in
            guard let uid = value.nativeInt("uid"), uid > 0, let name = value.nativeString("name"),
                  seen.insert(uid).inserted, query.isEmpty || name.localizedCaseInsensitiveContains(query) else { return nil }
            return AccountUserRow(id: uid, name: name, avatar: value.nativeString("avatarUrl"))
        }
    }
}
