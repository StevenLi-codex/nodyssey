import SwiftUI
import NodysseyNativeCore

/// One surface per My-page group, never per tile or nested inside another glass card.
/// The pre-iOS 26 material is deliberately a fallback, not simulated Liquid Glass.
struct AccountProfileGroupSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        if reduceTransparency || contrast == .increased {
            AccountSurface()
                .overlay { shape.fill(.tint).opacity(0.04) }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.25 : 0.08), lineWidth: 0.5) }
        } else {
            #if os(iOS) && compiler(>=6.2)
            if #available(iOS 26.0, *) {
                Color.clear
                    .overlay { shape.fill(.tint).opacity(0.035) }
                    .glassEffect(.regular, in: shape)
            } else {
                materialSurface
            }
            #else
            materialSurface
            #endif
        }
    }

    private var materialSurface: some View {
        shape.fill(.regularMaterial)
            .overlay { shape.fill(.tint).opacity(0.035) }
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

/// Shared horizontal inset for every My-page group, including the attendance row.
struct AccountProfileGroupRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AccountProfileGroupSurface())
    }
}

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
        // Original ProfileScreen uses four tracks, including a short final row.
        // Only accessibility categories change the column count, not phone width.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: 4) {
            ForEach(entries) { entry in
                Button { app.open(entry.route, entry.arguments) } label: {
                    VStack(spacing: 7) {
                        Image(systemName: entry.symbol).font(.body).foregroundStyle(.tint).accessibilityHidden(true)
                        Text(LocalizedStringKey(entry.title)).font(.caption.weight(.medium)).foregroundStyle(.primary)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 4)
    }
}

/// Compact My-page identity, deliberately separate from the full space header.
/// Bio, full registration date and repeated rank belong to the space, not here.
struct AccountProfileIdentity: View {
    @Environment(\.locale) private var locale
    let profile: JSONValue
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(.secondary.opacity(0.10))
                if let url = profile.nativeString("avatarUrl"), !url.isEmpty { NativeRemoteImage(url: url) }
                else { Image(systemName: "person.fill").foregroundStyle(.secondary) }
            }.frame(width: 44, height: 44).clipShape(Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.nativeString("name") ?? "").font(.headline).lineLimit(1)
                if let uid = profile.nativeInt("uid") {
                    if let raw = profile.nativeString("createdAt"), let month = AccountProfileDate.registrationMonth(raw) {
                        // String arguments preserve the full Kotlin Long domain; %d would truncate UID.
                        Text(String(format: String(localized: "native.account.member_since", table: "Account"), locale: locale,
                                    String(month.year), String(month.month), String(uid)))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else { Text("UID \(String(uid))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccountProfileWelcome: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.fill").font(.system(size: 40))
                .foregroundStyle(.tint).frame(width: 96, height: 96)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 32))
                .accessibilityHidden(true)
            Text(String(format: String(localized: "profile_signed_out_title"), app.siteName ?? ""))
                .font(.title3.bold()).multilineTextAlignment(.center).accessibilityAddTraits(.isHeader)
                .padding(.top, 8)
            Text("profile_signed_out_body").font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.padding(.vertical, 16).frame(maxWidth: .infinity)
    }
}

struct AccountProfileBenefit: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 4)
    }
}

struct AccountProfileAttendance: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var status = NativeStore()
    @StateObject private var action = AccountAction()
    @State private var choosing = false
    @State private var attendance = AccountAttendanceState()
    @State private var attendanceGeneration: Int?
    @State private var attendanceNow = Date()
    @Environment(\.scenePhase) private var scenePhase
    private var attendanceScope: AccountAttendanceState.Scope? {
        guard let uid = status.value["uid"]?.int,
              let epoch = app.session["identityEpoch"]?.string,
              let site = app.activeSite?.rawValue else { return nil }
        return .init(generation: app.generation, identityEpoch: epoch, site: site, uid: uid)
    }
    private var presentation: AccountAttendanceState.Presentation {
        guard attendanceGeneration == app.generation else { return app.isSignedIn ? .unknown : .guest }
        return attendance.presentation(status: status.value, isSignedIn: app.isSignedIn, scope: attendanceScope, now: attendanceNow)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.isSignedIn {
                AccountStoreStatus(store: status) { Task { await status.load(app, "attendance.status") } }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if case let .reward(gain) = presentation {
                            Text(String(format: String(localized: "native.account.attendance_reward", table: "Account"), String(gain)))
                                .font(.subheadline.weight(.semibold))
                        } else if presentation.isDone {
                            Text(String(localized: "native.account.attendance_amount_unavailable", table: "Account"))
                                .font(.subheadline.weight(.semibold))
                        } else if presentation == .unsigned {
                            Button("profile_attendance_title") { choosing = true }.disabled(action.blocked || status.isLoading)
                            Text("profile_attendance_modes").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("profile_attendance_checking").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { app.open("Assets") } label: {
                        HStack(spacing: 4) {
                            Text(String(localized: "native.account.attendance_view_board", table: "Account"))
                            Image(systemName: "chevron.right").accessibilityHidden(true)
                        }.font(.caption).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 8)
                    }.buttonStyle(.plain).foregroundStyle(.tint)
                }
                AccountActionStatus(action: action)
            }
        }
        .task(id: app.generation) {
            choosing = false
            if attendanceGeneration != app.generation {
                action.cancel(); attendance.reset(); status.invalidate(); attendanceGeneration = app.generation
            }
            if app.isSignedIn { await status.loadIfStale(app, "attendance.status") }
        }
        .confirmationDialog("profile_attendance_title", isPresented: $choosing, titleVisibility: .visible) {
            Button(String(localized: "native.account.attendance_fixed", table: "Account")) { sign("FIXED_FIVE") }
            Button(String(localized: "native.account.attendance_random", table: "Account")) { sign("RANDOM") }
            Button("action_cancel", role: .cancel) {}
        } message: { Text("profile_attendance_modes") }
        // A pushed destination is not identity revocation. Keep the existing
        // action alive, including its uncertain-write gate and read-only retry.
        .onDisappear { choosing = false }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await checkAttendanceDay() } }
        }
        .task {
            await checkAttendanceDay()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                await checkAttendanceDay()
            }
        }
    }
    private func checkAttendanceDay() async {
        let now = Date()
        let changed = AccountAttendanceState.siteDay(now) != AccountAttendanceState.siteDay(attendanceNow)
        attendanceNow = now
        guard changed, app.isSignedIn, attendanceGeneration == app.generation else { return }
        choosing = false
        if action.canRefresh { action.refreshOnly() }
        else if !action.blocked { await status.load(app, "attendance.status") }
    }
    private func sign(_ mode: String) {
        guard app.isSignedIn, presentation == .unsigned, !action.blocked,
              let scope = attendanceScope,
              let day = status.value["date"]?.string,
              day == AccountAttendanceState.siteDay() else { return }
        let generation = app.generation
        action.perform(app, operation: "attendance.sign", arguments: ["mode": .string(mode), "confirmed": .bool(true)], read: {
            // Load through the store's owner, not its public value: cancellation
            // must not restore the pre-write internal snapshot over this readback.
            await status.load(app, "attendance.status")
            try Task.checkCancellation()
            guard generation == app.generation else { throw CancellationError() }
            if let failure = status.failure { throw failure }
            guard status.value["uid"]?.int == scope.uid,
                  let date = status.value["date"]?.string, date >= day,
                  status.value["hasSignedIn"]?.bool != nil else {
                throw NativeFailure(code: "INVALID_RESPONSE", message: "")
            }
        }, received: { attendance.receive($0, scope: scope, day: day) })
    }
}

struct AccountProfileBalances: View {
    @EnvironmentObject private var app: NativeAppModel
    let profile: JSONValue
    var body: some View {
        HStack(spacing: 2) { balances }
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(key == "rank"
                     ? profile.nativeInt(key).map { "Lv \($0)" } ?? String(localized: "profile_level_unknown")
                     : profile.nativeInt(key).map(String.init) ?? "—")
                    .font(.headline).monospacedDigit().foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.padding(10).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .background(.tint.opacity(0.08))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
    }
}
