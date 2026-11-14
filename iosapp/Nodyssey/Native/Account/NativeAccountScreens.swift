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

/// No persistent Swift mirror; every mutation refreshes the repository it actually changed.
@MainActor
final class AccountAction: ObservableObject {
    @Published var state = AccountMutationState()
    @Published var failure: NativeFailure?
    private var task: Task<Void, Never>?
    private var readBack: (() async throws -> Void)?
    var blocked: Bool { state.blocksWrite }

    func perform(_ app: NativeAppModel, operation: String, arguments: [String: JSONValue],
                 read: @escaping () async throws -> Void, received: @escaping (JSONValue) -> Void = { _ in }) {
        guard let ticket = state.begin(confirmed: true) else { return }
        let generation = app.generation
        failure = nil; readBack = read
        task = Task {
            do {
                let result = try await app.request(operation, arguments)
                guard !Task.isCancelled, app.generation == generation, state.ticket == ticket else { return }
                state.acknowledge(ticket)
                received(result)
                do {
                    try await read()
                    guard !Task.isCancelled, app.generation == generation else { return }
                    state.refreshed(ticket)
                } catch {
                    guard !Task.isCancelled, app.generation == generation else { return }
                    state.readFailed(ticket); failure = accountFailure(error)
                }
            } catch {
                guard !Task.isCancelled, app.generation == generation else { return }
                state.writeFailed(ticket); failure = accountFailure(error)
            }
        }
    }
    func refreshOnly() {
        guard let ticket = state.ticket, let readBack else { return }
        task = Task {
            do { try await readBack(); try Task.checkCancellation(); state.refreshed(ticket); failure = nil }
            catch { if !Task.isCancelled { failure = accountFailure(error) } }
        }
    }
    func cancel() { task?.cancel(); task = nil; readBack = nil; state.invalidate(); failure = nil }
}

func accountFailure(_ error: Error) -> NativeFailure {
    NativeFailure(code: (error as? NativeFailure)?.code ?? "INTERNAL", message: "")
}

struct AccountActionStatus: View {
    @ObservedObject var action: AccountAction
    var body: some View {
        if action.state.phase == .writing || action.state.phase == .reading { ProgressView() }
        if action.state.phase == .verified { Text("account_action_saved").foregroundStyle(.secondary) }
        if action.state.phase == .savedNeedsRefresh { Text("native.account.saved_refresh", tableName: "Account") }
        if action.state.phase == .uncertain { Text("native.account.uncertain", tableName: "Account") }
        if let failure = action.failure { NativeFailureView(failure: failure, retry: action.refreshOnly) }
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

struct AccountProfileHeader: View {
    let profile: JSONValue
    var body: some View {
        HStack {
            if let url = profile.nativeString("avatarUrl") { NativeRemoteImage(url: url).frame(width: 64, height: 64).clipShape(Circle()) }
            VStack(alignment: .leading) {
                Text(profile.nativeString("name") ?? "").font(.title2)
                if let uid = profile.nativeInt("uid") { Text("UID \(String(uid))").font(.caption).textSelection(.enabled) }
                if let rank = profile.nativeInt("rank") { LabeledContent("profile_level", value: String(rank)) }
                if let chicken = profile.nativeInt("chickenCount") { LabeledContent("profile_chicken", value: String(chicken)) }
                if let stars = profile.nativeInt("starCount") { LabeledContent("profile_stars", value: String(stars)) }
                if let date = profile.nativeString("createdAt") { Text(date).font(.caption) }
                if let bio = profile.nativeString("bio"), !bio.isEmpty { Text(bio).textSelection(.enabled) }
            }
        }
    }
}

struct AccountProfileScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var profile = NativeStore()
    var body: some View {
        List {
            if app.isSignedIn {
                AccountProfileHeader(profile: profile.value)
                AccountStoreStatus(store: profile) { Task { await profile.load(app, "profile.self", ["refresh": .bool(true)]) } }
                if let uid = profile.value.nativeInt("uid") {
                    Button("profile_space") { app.open("UserSpace", ["uid": .integer(uid), "isSelf": .bool(true)]) }
                }
                Section("profile_section_content") {
                    route("profile_tile_topics", "MyTopics")
                    route("profile_tile_comments", "MyComments")
                    route("profile_tile_collections", "Bookmarks")
                    Button("profile_tile_following") { app.open("Follow", ["showFollowers": .bool(false)]) }
                    Button("profile_tile_followers") { app.open("Follow", ["showFollowers": .bool(true)]) }
                    route("profile_attendance_title", "Assets")
                    route("profile_chicken", "Credit")
                    route("profile_stars", "Stardust")
                    route("profile_tile_account", "AccountSettings")
                }
            } else {
                Text("profile_signed_out_body")
                Button("action_sign_in") { app.showSignIn() }.accessibilityIdentifier("native.profile.signin")
            }
            Section("profile_guest_section") {
                route("profile_tile_history", "ReadHistory")
                route("profile_tools", "CommunityTools")
                route("profile_tile_about_community", "AboutCommunity")
                Button("profile_section_settings") { app.open("Settings") }.accessibilityIdentifier("native.profile.settings")
            }
        }
        .navigationTitle("profile_space")
        .task(id: app.generation) { await profile.observe(app, "profile.self") }
        .refreshable { await profile.load(app, "profile.self", ["refresh": .bool(true)]) }
    }
    private func route(_ title: String, _ destination: String) -> some View {
        Button(LocalizedStringKey(title)) { app.open(destination) }
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
    private func row(_ title: String, _ route: String) -> some View { Button(LocalizedStringKey(title)) { app.open(route) } }
}
