import SwiftUI
import NodysseyNativeCore

@MainActor
enum NativeAccountScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        switch destination.route {
        case "Profile": return AnyView(AccountProfileScreen())
        case "SignIn": return AnyView(AccountSignInScreen())
        case "AccountSettings": return AnyView(AccountSettingsScreen())
        case "AccountProfileFields": return AnyView(AccountProfileFieldsScreen())
        case "AccountSecurity": return AnyView(AccountSecurityScreen())
        case "AccountContact": return AnyView(AccountContactScreen())
        case "AccountBlockList": return AnyView(AccountBlockScreen(titles: destination.arguments["titles"]?.bool == true))
        case "AccountPreferences": return AnyView(AccountPreferencesScreen())
        case "UserSpace":
            guard let uid = destination.arguments["uid"]?.int, uid > 0 else { return AnyView(AccountInvalidRoute()) }
            return AnyView(AccountSpaceScreen(uid: uid, requestedCollections: destination.arguments["openCollections"]?.bool == true))
        case "Follow": return AnyView(AccountFollowScreen(followers: destination.arguments["showFollowers"]?.bool == true))
        case "MyTopics": return AnyView(AccountOwnPostsScreen(comments: false))
        case "MyComments": return AnyView(AccountOwnPostsScreen(comments: true))
        default: return nil
        }
    }
}

struct AccountInvalidRoute: View {
    var body: some View { NativeFailureView(failure: NativeFailure(code: "INVALID_ARGUMENT", message: "")) }
}

@MainActor
extension AccountAction {
    func perform(_ app: NativeAppModel, operation: String, arguments: [String: JSONValue],
                 read: @escaping () async throws -> Void, received: @escaping (JSONValue) -> Void = { _ in }) {
        perform(operation: operation, arguments: arguments, request: { try await app.request($0, $1) },
                currentGeneration: { app.generation }, read: read, received: received)
    }
}

struct AccountActionStatus: View {
    @ObservedObject var action: AccountAction
    var body: some View {
        if action.state.phase == .writing || action.state.phase == .reading || action.isRefreshing { ProgressView() }
        if action.state.phase == .verified { Text("account_action_saved").foregroundStyle(.secondary) }
        if action.state.phase == .savedNeedsRefresh { Text("native.account.saved_refresh", tableName: "Account") }
        if action.state.phase == .uncertain { Text("native.account.uncertain", tableName: "Account") }
        if action.state.phase == .reconciled { Text("native.account.reconciled", tableName: "Account") }
        if action.state.phase == .rejected { Text("native.account.correct_input", tableName: "Account") }
        if let failure = action.failure { NativeFailureView(failure: failure) }
        // Recovery is read-only and must not depend on generic error retry policy.
        if action.canRefresh {
            Button { action.refreshOnly() } label: { Text("native.account.reconcile", tableName: "Account") }
                .accessibilityIdentifier("native.account.reconcile")
        }
    }
}

struct AccountStoreStatus: View {
    @ObservedObject var store: NativeStore
    var retry: () -> Void
    var body: some View {
        if store.isLoading { ProgressView() }
        if let failure = store.failure { NativeFailureView(failure: failure, retry: retry) }
    }
}

struct AccountRequireSignIn: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        Text("profile_signed_out_body")
        Button("action_sign_in") { app.showSignIn() }
    }
}

struct AccountSurface: View {
    @Environment(\.colorScheme) private var scheme
    var canvas = false
    var body: some View {
        (scheme == .dark
            ? (canvas ? Color(.sRGB, white: 0.035, opacity: 1) : Color(.sRGB, white: 0.085, opacity: 1))
            : (canvas ? Color(.sRGB, white: 0.95, opacity: 1) : Color.white))
    }
}

struct AccountProfileHeader: View {
    @Environment(\.locale) private var locale
    let profile: JSONValue
    var showBalances = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(.secondary.opacity(0.10))
                    if let url = profile.nativeString("avatarUrl"), !url.isEmpty { NativeRemoteImage(url: url) }
                    else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
                }.frame(width: 48, height: 48).clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.nativeString("name") ?? "").font(.title3.weight(.semibold)).foregroundStyle(.primary)
                    if let uid = profile.nativeInt("uid") {
                        Text("UID \(String(uid))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let rank = profile.nativeInt("rank") {
                        HStack(spacing: 4) { Text("profile_level"); Text(String(rank)) }
                            .font(.caption.weight(.medium)).foregroundStyle(.tint)
                    }
                }
                Spacer(minLength: 0)
            }
            if let bio = profile.nativeString("bio"), !bio.isEmpty {
                Text(bio).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let raw = profile.nativeString("createdAt"), let date = AccountProfileDate.formatted(raw, locale: locale) {
                Text(String(format: String(localized: "native.account.joined", table: "Account"), locale: locale, date))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if showBalances && (profile.nativeInt("chickenCount") != nil || profile.nativeInt("starCount") != nil) {
                HStack(spacing: 28) {
                    if let count = profile.nativeInt("chickenCount") { AccountProfileStat(title: "profile_chicken", value: count) }
                    if let count = profile.nativeInt("starCount") { AccountProfileStat(title: "profile_stars", value: count) }
                }
            }
        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccountProfileStat: View {
    let title: LocalizedStringKey
    let value: Int64
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(String(value)).font(.headline).monospacedDigit().foregroundStyle(.primary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct AccountProfileStatus: View {
    @ObservedObject var profile: AccountSelfProfileState
    var body: some View {
        if profile.isLoading && profile.value == .null { ProgressView("loading_indicator_label") }
        if let failure = profile.failure { NativeFailureView(failure: failure) }
        if profile.failure != nil || (profile.value == .null && !profile.isLoading) {
            Text("native.account.profile_unavailable", tableName: "Account")
            Button { Task { await profile.refresh() } } label: { Text("native.account.reconcile", tableName: "Account") }
        }
    }
}

struct AccountProfileScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var profile = AccountSelfProfileState()
    var body: some View {
        List {
            if app.isSignedIn {
                Section {
                    if let uid = profile.value.nativeInt("uid") {
                        Button { app.open("UserSpace", ["uid": .integer(uid), "isSelf": .bool(true)]) } label: {
                            HStack {
                                AccountProfileHeader(profile: profile.value, showBalances: false)
                                if profile.isLoading { ProgressView().controlSize(.small).accessibilityLabel(Text("loading_indicator_label")) }
                                else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                            }
                        }.buttonStyle(.plain).accessibilityHint(Text("profile_space"))
                    } else if profile.value != .null {
                        AccountProfileHeader(profile: profile.value, showBalances: false)
                    }
                    AccountProfileStatus(profile: profile)
                    AccountProfileBalances(profile: profile.value)
                    AccountProfileAttendance()
                }
                Section("profile_section_content") {
                    AccountProfileDirectory(entries: [
                        .init("profile_tile_topics", "text.bubble", "MyTopics"),
                        .init("profile_tile_comments", "bubble.left.and.bubble.right", "MyComments"),
                        .init("profile_tile_collections", "bookmark", "Bookmarks"),
                        .init("profile_tile_history", "clock", "ReadHistory"),
                        .init("profile_tile_following", "person.badge.plus", "Follow", ["showFollowers": .bool(false)]),
                        .init("profile_tile_followers", "person.2", "Follow", ["showFollowers": .bool(true)])
                    ])
                }
                Section("profile_section_community") {
                    AccountProfileDirectory(entries: [
                        .init("profile_tile_award", "book", "Award"),
                        .init("profile_tile_lucky", "dice", "Lucky"),
                        .init("profile_tile_ruling", "checkmark.shield", "Ruling"),
                        .init("profile_tile_invite", "ticket", "Invite"),
                        .init("profile_tools", "wrench.and.screwdriver", "CommunityTools"),
                        .init("profile_tile_block", "hand.raised", "AccountBlockList", ["titles": .bool(false)]),
                        .init("profile_tile_about_community", "info.circle", "AboutCommunity")
                    ])
                }
                Section { AccountProfileWebShortcuts() }
                Section("profile_section_settings") {
                    AccountProfileDirectory(entries: [
                        .init("profile_tile_account", "person.crop.circle", "AccountSettings"),
                        .init("profile_tile_notifications", "bell", "NotificationSettings"),
                        .init("profile_tile_theme", "paintpalette", "ThemeSettings"),
                        .init("profile_tile_about", "info.circle", "AboutApp")
                    ])
                    Button { app.open("Settings") } label: { navigationLabel("settings_title", symbol: "gearshape") }
                        .accessibilityIdentifier("native.profile.settings")
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "person.crop.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("profile_signed_out_body").font(.body)
                    Button("action_sign_in") { app.showSignIn() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .accessibilityIdentifier("native.profile.signin")
                }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !app.isSignedIn { Section("profile_guest_section") {
                route("profile_tile_history", "ReadHistory")
                route("profile_tools", "CommunityTools")
                route("profile_tile_award", "Award")
                route("profile_tile_lucky", "Lucky")
                route("profile_tile_ruling", "Ruling")
                AccountProfileWebShortcuts()
                route("profile_tile_about", "AboutApp")
                route("profile_tile_about_community", "AboutCommunity")
                Button { app.open("Settings") } label: { navigationLabel("settings_title", symbol: "gearshape") }
                    .accessibilityIdentifier("native.profile.settings")
            } }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .listRowSeparatorTint(.secondary.opacity(0.15))
        .background(AccountSurface(canvas: true))
        .navigationTitle("profile_space")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: app.generation) {
            if app.isSignedIn { await profile.run(using: app.transport, currentGeneration: { app.generation }) }
            else { profile.invalidate() }
        }
        .refreshable { await profile.refresh() }
    }
    private func route(_ title: String, _ destination: String) -> some View {
        let symbols = ["MyTopics": "text.bubble", "MyComments": "bubble.left.and.bubble.right", "Bookmarks": "bookmark",
                       "Assets": "calendar", "Credit": "gift", "Stardust": "star", "AccountSettings": "person.crop.circle.badge.gearshape",
                       "ReadHistory": "clock", "CommunityTools": "wrench.and.screwdriver", "AboutCommunity": "info.circle"]
        return Button { app.open(destination) } label: { navigationLabel(title, symbol: symbols[destination] ?? "chevron.right") }
    }
    private func navigationLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body).frame(width: 24).foregroundStyle(.secondary)
            Text(LocalizedStringKey(title)).font(.body).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
}

struct AccountSettingsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var profile = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var signOut = false
    var body: some View {
        Form {
            if app.isSignedIn {
                AccountProfileHeader(profile: profile.value)
                AccountStoreStatus(store: profile) { reload() }
                Text("account_storage_legend").font(.footnote).foregroundStyle(.secondary)
                row("account_profile_title", "AccountProfileFields")
                row("account_security_title", "AccountSecurity")
                row("account_contact_title", "AccountContact")
                row("account_block_title", "AccountBlockList")
                row("account_preferences_title", "AccountPreferences")
                Button("action_sign_out", role: .destructive) { signOut = true }.disabled(action.blocked)
                AccountActionStatus(action: action)
            } else { AccountRequireSignIn() }
        }
        .disabled(action.state.phase == .writing || action.state.phase == .reading)
        .navigationTitle("account_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: app.generation) { action.cancel(); await profile.load(app, "profile.self", ["refresh": .bool(true)]) }
        .refreshable { await profile.load(app, "profile.self", ["refresh": .bool(true)]) }
        .confirmationDialog("action_sign_out", isPresented: $signOut, titleVisibility: .visible) {
            Button("action_sign_out", role: .destructive) {
                action.perform(app, operation: "session.signOut", arguments: ["confirmed": .bool(true)], read: {
                    _ = try await app.request("session.snapshot")
                })
            }
        }
        .onDisappear { action.cancel() }
    }
    private func reload() { Task { await profile.load(app, "profile.self", ["refresh": .bool(true)]) } }
    private func row(_ title: String, _ route: String) -> some View {
        Button { app.open(route) } label: {
            HStack { Text(LocalizedStringKey(title)); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
