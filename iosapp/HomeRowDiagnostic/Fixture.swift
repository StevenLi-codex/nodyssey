import SwiftUI
import NodysseyNativeCore

@main struct RetentionProbeApp: App {
    @StateObject private var fixture: FixtureTransport
    @StateObject private var app: NativeAppModel
    init() {
        let transport = FixtureTransport()
        _fixture = StateObject(wrappedValue: transport)
        _app = StateObject(wrappedValue: NativeAppModel(transport: transport))
    }
    var body: some Scene { WindowGroup {
        NativeRootView().environmentObject(app).environmentObject(fixture)
            .overlay(alignment: .topLeading) { RetentionGeometryProbe().frame(width: 1, height: 1).allowsHitTesting(false) }
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-profile") ? .accessibility2 : .large)
    } }
}
// Real NativeRootView, NativeAppModel, NativeStore, NativeRequestState and root
// screen declarations compile together. Only non-root destinations/image/theme
// and the Kotlin/network boundary are replaced; no production fixture hooks.
struct FixtureDestination: View { let name: String; var body: some View { Text("Destination " + name).accessibilityIdentifier("destination").navigationTitle("Detail") } }
enum NativeAccountScreens { static func make(destination: NativeDestination) -> AnyView? { destination.route == "Profile" ? AnyView(AccountProfileScreen()) : destination.route == "SignIn" ? AnyView(FixtureThemeDestination()) : nil } }
enum NativeEditorScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
enum NativeLibraryScreens { static func make(destination: NativeDestination) -> AnyView? { destination.route == "ThemeOther" ? AnyView(FixtureOtherChoice()) : ["Settings", "ThemeSettings", "SignIn"].contains(destination.route) ? nil : AnyView(FixtureDestination(name: destination.route)) } }
enum NativeSettingsScreens { static func make(destination: NativeDestination) -> AnyView? {
    ["Settings", "ThemeSettings"].contains(destination.route) ? AnyView(FixtureThemeDestination()) : nil
} }
struct FixtureThemeDestination: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        SettingsThemeScreen()
            .overlay(alignment: .bottom) {
                VStack {
                HStack {
                    Rectangle().fill(.tint).frame(width: 20, height: 20)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Tint swatch").accessibilityIdentifier("theme70.tint")
                    Rectangle().fill(Color.accentColor).frame(width: 20, height: 20)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Accent swatch").accessibilityIdentifier("theme70.accent")
                    Text(["themeMode", "colorSource", "presetId"].map { app.settings[$0]?.string ?? "null" }.joined(separator: "/"))
                        .accessibilityIdentifier("theme70.state").font(.caption2)
                }
                FixtureSaveGateControls()
                }
            }
            .background(ThemeTintProbe(settings: app.settings, checkpoint: 0, scope: "production-theme").frame(width: 0, height: 0))
            .toolbar {
                Button("Sheet") { app.open("SignIn") }.accessibilityIdentifier("theme70.sheet")
                Button("Detail") { app.open("ThemeProbeDetail") }.accessibilityIdentifier("theme70.detail")
                Button("Other") { app.open("ThemeOther") }.accessibilityIdentifier("theme70.other")
            }
    }
}
struct FixtureOtherChoice: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = SettingsAction()
    var body: some View {
        Form {
            SettingsChoice(action: action, key: "appLanguage", title: "settings_language", choices: [
                ("SYSTEM", "settings_language_system"), ("ENGLISH", "settings_language_en")
            ])
            Text(app.settings["appLanguage"]?.string ?? "missing").accessibilityIdentifier("theme70.language")
        }.modifier(SettingsLifecycle(action: action))
            .overlay(alignment: .bottom) { FixtureSaveGateControls() }
    }
}
struct FixtureSaveGateControls: View {
    @EnvironmentObject private var fixture: FixtureTransport
    var body: some View {
        HStack {
            Text("\(fixture.saveStarts)/\(fixture.saveReleases)")
                .accessibilityIdentifier("theme70.saveGate")
            Button("Release save") { fixture.releaseSave() }
                .accessibilityIdentifier("theme70.release")
        }.font(.caption2)
    }
}
enum NativeMediaScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
struct NativeExternalBrowser: View { let url: URL; var body: some View { EmptyView() } }
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
struct ContentPostDetail: View { let postID: Int64; let initialFloor: String?; let initialPage: Int64?; let preview: JSONValue?; var body: some View { FixtureDestination(name: "PostDetail") } }
struct ContentBoardManager: View { let categories: JSONValue; @Binding var selection: String; var body: some View { EmptyView() } }

enum AccountAuthorQuickCardNavigation { case signIn; case route(String, [String: JSONValue]) }
struct AccountAuthorQuickCard: View { let uid: Int64; let onNavigate: (AccountAuthorQuickCardNavigation) -> Void; var body: some View { Text("Author card") } }

@MainActor final class FixtureTransport: ObservableObject, NativeTransport {
    @Published private(set) var saveStarts = 0
    @Published private(set) var saveReleases = 0
    private var pendingSave: CheckedContinuation<Void, Never>?
    func releaseSave() {
        guard let pending = pendingSave else { return }
        pendingSave = nil
        saveReleases += 1
        pending.resume()
    }
    @Published var profileReads = 0
    @Published var notificationStarts = 0
    @Published var feedStarts = 0
    private var session: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var boundary: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var feeds: [AsyncThrowingStream<JSONValue, Error>.Continuation] = []
    var revoked = false
    private var settings: JSONValue = .object(["onboardingSeen": .bool(true), "homePageBar": .bool(true),
        "appLanguage": .string("ENGLISH"), "themeMode": .string(ProcessInfo.processInfo.arguments.contains("--system-dark") ? "SYSTEM" : ProcessInfo.processInfo.arguments.contains("--dark") ? "DARK" : "LIGHT"),
        "colorSource": .string("PRESET"), "presetId": .string("twins"), "paletteStyle": .string("SOFT"),
        "seedColor": .integer(-13279122), "einkMode": .bool(false)])
    private var profile: JSONValue { .object(["uid": .integer(123), "name": .string("Retained reader"), "chickenCount": .integer(234), "starCount": .integer(12), "rank": .integer(5)]) }
    private var site: JSONValue { .object(["current": .string("DEEPFLOOD"), "selected": .string("DEEPFLOOD"), "requiresRestart": .bool(false), "sites": .array([.object(["id": .string("DEEPFLOOD"), "origin": .string("https://www.deepflood.com"), "displayName": .string("Fixture")])])]) }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        switch operation {
        case "settings.get": return settings
        case "settings.set":
            // Fixture-only handshake: real menu/action owns busy until XCTest
            // verifies disabled hit rejection and explicitly releases transport.
            saveStarts += 1
            await withCheckedContinuation { continuation in
                precondition(pendingSave == nil, "Duplicate settings write while held")
                pendingSave = continuation
            }
            try Task.checkCancellation()
            var fields = settings.object ?? [:]
            if let key = arguments["key"]?.string, let value = arguments["value"] { fields[key] = value }
            settings = .object(fields)
            return settings
        case "site.get": return site
        case "profile.self": profileReads += 1; return profile
        case "attendance.status": return .object(["uid": .integer(123), "date": .string("2026-11-16"), "hasSignedIn": .bool(true), "gain": .integer(14)])
        case "paging.access", "paging.refresh", "categories.refresh", "app.foreground", "boards.recent.record", "notifications.read", "notifications.refresh", "messages.refresh": return .null
        default: throw NativeFailure(code: "BOUNDARY", message: operation)
        }
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            switch operation {
            case "session.state":
                session = continuation
                continuation.yield(.object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)]))
            case "session.privateBoundary":
                boundary = continuation
                continuation.yield(.object(["identityEpoch": .string("A"), "phase": .string("READY"), "requiresConfirmation": .bool(false), "recoveryEligible": .bool(false)]))
            case "settings.observe": continuation.yield(settings)
            case "profile.self": continuation.yield(profile)
            case "categories", "boards.recent", "messages.list": continuation.yield(.array([]))
            case "notifications.counts": continuation.yield(.object(["interactions": .integer(40), "messages": .integer(0)]))
            case "notifications.list":
                notificationStarts += 1
                let rows: [JSONValue] = (0..<60).map { i in
                    .object(["id": .string("n\(i)"), "sourceId": .integer(Int64(i+1)), "sources": .array([.object(["id": .string("n\(i)"), "category": .string("REPLIES")])]), "category": .string("REPLIES"), "actorUid": .integer(123), "actorName": .string("Reader"), "threadTitle": .string("Notification \(i)"), "createdAtText": .string("Notification \(i)"), "postId": .integer(Int64(i+1)), "isReply": .bool(true), "isUnread": .bool(true)])
                }
                continuation.yield(.array(rows))
            case "feed":
                feedStarts += 1; feeds.append(continuation)
                let handle = arguments["pagerId"] ?? .string("fixture")
                let loading: JSONValue = .object(["pagerId": handle, "items": .array([]), "refresh": .object(["status": .string("Loading")])])
                continuation.yield(loading)
                let snapshot = feed(handle)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(snapshot) // Deliberate late callback for revocation test.
                }
            default: continuation.finish(throwing: NativeFailure(code: "BOUNDARY", message: operation))
            }
        }
    }
    private func feed(_ handle: JSONValue) -> JSONValue {
        let rows: [JSONValue] = (0..<60).map { i in
            let summary: [String: JSONValue] = ["postId": .integer(9007199254741001 + Int64(i)), "authorUid": .integer(123), "authorName": .string("Author \(i)"), "title": .string("Post \(i)"), "categoryTitle": .string("Board"), "commentCount": .integer(12), "viewCount": .integer(345), "lastActiveText": .string("5 min")]
            return .object(["page": .integer(Int64(i/10+1)), "summary": .object(summary)])
        }
        return .object(["pagerId": handle, "items": .array(rows), "placeholdersBefore": .integer(0), "placeholdersAfter": .integer(0), "itemCount": .integer(60), "totalPages": .integer(6), "refresh": .object(["status": .string("NotLoading")])])
    }
    func revoke() {
        revoked = true
        session?.yield(.object(["identityEpoch": .string("B"), "isSignedIn": .bool(false), "generation": .integer(2)]))
        boundary?.yield(.object(["identityEpoch": .string("B"), "phase": .string("READY"), "requiresConfirmation": .bool(false), "recoveryEligible": .bool(false)]))
        for c in feeds { c.yield(feed(.string("late-A"))) }
    }
}
