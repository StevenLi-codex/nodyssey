import SwiftUI
import NodysseyNativeCore

/// The Android profile is a directory, not a long settings menu. Keep its
/// content/community grouping, with native symbols and no per-entry card chrome.
struct AccountProfileDirectory: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entries: [Entry]

    struct Entry: Identifiable {
        let title: String
        let symbol: String
        let route: String
        let arguments: [String: JSONValue]
        var id: String { title }
        init(_ title: String, _ symbol: String, _ route: String, _ arguments: [String: JSONValue] = [:]) {
            self.title = title; self.symbol = symbol; self.route = route; self.arguments = arguments
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 240 : 88), spacing: 8)], spacing: 8) {
            ForEach(entries) { entry in
                Button { app.open(entry.route, entry.arguments) } label: {
                    VStack(spacing: 7) {
                        Image(systemName: entry.symbol).font(.body).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(LocalizedStringKey(entry.title)).font(.subheadline).foregroundStyle(.primary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 4)
    }
}

/// Paths are the existing NodeSeekSite.PROVIDERS_PATH / FRIENDS_PATH, resolved
/// against the installed site's origin rather than a second browser/session graph.
struct AccountProfileWebShortcuts: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        if let origin = app.siteOrigin {
            AccountProfileDirectory(entries: [
                .init("profile_tile_providers", "building.2", "Web", ["url": .string(origin + "/providers"), "goal": .string("EXTERNAL"), "title": .string(String(localized: "profile_tile_providers"))]),
                .init("profile_tile_friends", "link", "Web", ["url": .string(origin + "/friends"), "goal": .string("EXTERNAL"), "title": .string(String(localized: "profile_tile_friends"))])
            ])
        }
    }
}

struct AccountProfileAttendance: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var status = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountStoreStatus(store: status) { Task { await status.load(app, "attendance.status") } }
            if let signed = status.value.nativeBool("hasSignedIn") {
                if signed {
                    Button("profile_attendance_done") { app.open("Assets") }
                } else {
                    Button("profile_attendance_title") { choosing = true }.disabled(action.blocked || status.isLoading)
                    Text("profile_attendance_modes").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("profile_attendance_board") { app.open("Assets") }
            AccountActionStatus(action: action)
        }
        .task(id: app.generation) {
            choosing = false; action.cancel(); status.invalidate()
            if app.isSignedIn { await status.load(app, "attendance.status") }
        }
        .confirmationDialog("profile_attendance_title", isPresented: $choosing, titleVisibility: .visible) {
            Button(String(localized: "native.account.attendance_fixed", table: "Account")) { sign("FIXED_FIVE") }
            Button(String(localized: "native.account.attendance_random", table: "Account")) { sign("RANDOM") }
            Button("action_cancel", role: .cancel) {}
        } message: { Text("profile_attendance_modes") }
        .onDisappear { choosing = false; action.cancel() }
    }
    private func sign(_ mode: String) {
        guard app.isSignedIn, status.value.nativeBool("hasSignedIn") == false, !action.blocked else { return }
        let generation = app.generation
        action.perform(app, operation: "attendance.sign", arguments: ["mode": .string(mode), "confirmed": .bool(true)], read: {
            let fresh = try await app.request("attendance.status")
            try Task.checkCancellation()
            guard generation == app.generation else { return }
            status.value = fresh
        })
    }
}

struct AccountProfileBalances: View {
    @EnvironmentObject private var app: NativeAppModel
    let profile: JSONValue
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { balances }
            VStack(alignment: .leading, spacing: 4) { balances }
        }
    }
    private var balances: some View {
        Group {
            balance("profile_chicken", key: "chickenCount", route: "Credit")
            balance("profile_stars", key: "starCount", route: "Stardust")
            balance("profile_level", key: "rank", route: "Assets")
        }
    }
    private func balance(_ title: LocalizedStringKey, key: String, route: String) -> some View {
        Button { app.open(route) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.nativeInt(key).map(String.init) ?? "—").font(.headline).monospacedDigit().foregroundStyle(.primary)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}
