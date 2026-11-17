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
            .overlay(alignment: .topLeading) { Text(fixture.trace).font(.system(size: 1)).frame(width: 1, height: 1).accessibilityIdentifier("glass71.transport").allowsHitTesting(false) }
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-profile") ? .accessibility2 : .large)
    } }
}
// Diagnostic only. Kotlin/network and byte-loading are synthetic. All requested
// presentation screens, rich text, editor lifetime/input, stores/observers are production.
enum NativeAccountScreens { static func make(destination: NativeDestination) -> AnyView? { destination.route == "Profile" ? AnyView(AccountProfileScreen()) : nil } }
enum NativeLibraryScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
enum NativeSettingsScreens { static func make(destination: NativeDestination) -> AnyView? { destination.route == "ThemeSettings" ? AnyView(SettingsThemeScreen()) : nil } }
enum NativeMediaScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
struct NativeExternalBrowser: View { let url: URL; var body: some View { Text("External browser boundary") } }
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
@MainActor final class FixtureTransport: ObservableObject, NativeTransport {
    @Published var trace = "{}"
    private var events: [[String: Any]] = []
    private func record(_ kind: String, _ operation: String, _ arguments: [String: JSONValue]) {
        let args = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(arguments))) ?? [:]
        events.append(["kind":kind,"operation":operation,"arguments":args])
        trace = String(data: try! JSONSerialization.data(withJSONObject:["events":events], options:.sortedKeys),encoding:.utf8)!
    }
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
        "colorSource": .string(ProcessInfo.processInfo.arguments.contains("--custom") ? "CUSTOM" : "PRESET"), "presetId": .string("miku"), "paletteStyle": .string("SOFT"),
        "seedColor": .integer(-13279122), "einkMode": .bool(false)])
    private var profile: JSONValue { .object(["uid": .integer(123), "name": .string("Retained reader"), "chickenCount": .integer(234), "starCount": .integer(12), "rank": .integer(5)]) }
    private var site: JSONValue { .object(["current": .string("DEEPFLOOD"), "selected": .string("DEEPFLOOD"), "requiresRestart": .bool(false), "sites": .array([.object(["id": .string("DEEPFLOOD"), "origin": .string("https://www.deepflood.com"), "displayName": .string("Fixture")])])]) }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        record("request", operation, arguments)
        switch operation {
        case "settings.get": return settings
        case "settings.set":
            var fields = settings.object ?? [:]
            if let key = arguments["key"]?.string, let value = arguments["value"] { fields[key] = value }
            settings = .object(fields)
            return settings
        case "site.get": return site
        case "profile.self": profileReads += 1; return profile
        case "attendance.status": return .object(["uid": .integer(123), "date": .string("2026-11-16"), "hasSignedIn": .bool(true), "gain": .integer(14)])
        case "thread.get": return thread
        case "thread.status": return .object(["isCached":.bool(true),"hasUnread":.bool(false)])
        case "thread.position.get", "draft.comment.get": return .null
        case "thread.load", "thread.markRead", "thread.position.set", "search.history.record", "draft.comment.save", "draft.comment.delete": return .null
        case "paging.access", "paging.refresh", "categories.refresh", "app.foreground", "boards.recent.record", "notifications.read", "notifications.refresh", "messages.refresh": return .null
        default: throw NativeFailure(code: "BOUNDARY", message: operation)
        }
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        record("observe", operation, arguments)
        return AsyncThrowingStream { continuation in
            switch operation {
            case "session.state":
                session = continuation
                continuation.yield(.object(["identityEpoch": .string("A"), "isSignedIn": .bool(true), "generation": .integer(1)]))
            case "session.privateBoundary":
                boundary = continuation
                continuation.yield(.object(["identityEpoch": .string("A"), "phase": .string("READY"), "requiresConfirmation": .bool(false), "recoveryEligible": .bool(false)]))
            case "settings.observe": continuation.yield(settings)
            case "profile.self": continuation.yield(profile)
            case "categories": continuation.yield(.array([.object(["slug":.string("tech"),"title":.string("Tech")]),.object(["slug":.string("life"),"title":.string("Life")])]))
            case "boards.recent", "messages.list", "search.history", "tracked.observe": continuation.yield(.array([]))
            case "thread": continuation.yield(thread)

            case "notifications.counts": continuation.yield(.object(["interactions": .integer(40), "messages": .integer(0)]))
            case "notifications.list":
                notificationStarts += 1
                let rows: [JSONValue] = (0..<60).map { i in
                    .object(["id": .string("n\(i)"), "sourceId": .integer(Int64(i+1)), "sources": .array([.object(["id": .string("n\(i)"), "category": .string("REPLIES")])]), "category": .string("REPLIES"), "actorUid": .integer(123), "actorName": .string("Reader"), "threadTitle": .string("Notification \(i)"), "createdAtText": .string("Notification \(i)"), "postId": .integer(Int64(i+1)), "isReply": .bool(true), "isUnread": .bool(true)])
                }
                continuation.yield(.array(rows))
            case "feed", "search.feed":
                feedStarts += 1; feeds.append(continuation)
                let handle = arguments["pagerId"] ?? .string("fixture")
                let loading: JSONValue = .object(["pagerId": handle, "items": .array([]), "refresh": .object(["status": .string("Loading")])])
                continuation.yield(loading)
                let snapshot = feed(handle, prefix: operation == "search.feed" ? "Search" : arguments["categorySlug"]?.string ?? "Post")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(snapshot) // Deliberate late callback for revocation test.
                }
            default: continuation.finish(throwing: NativeFailure(code: "BOUNDARY", message: operation))
            }
        }
    }
    private func feed(_ handle: JSONValue, prefix: String = "Post") -> JSONValue {
        let rows: [JSONValue] = (0..<60).map { i in
            let summary: [String: JSONValue] = ["postId": .integer(9007199254741001 + Int64(i)), "authorUid": .integer(123), "authorName": .string("Author \(i)"), "title": .string("\(prefix) \(i)"), "categoryTitle": .string("Board"), "commentCount": .integer(12), "viewCount": .integer(345), "lastActiveText": .string("5 min")]
            return .object(["page": .integer(Int64(i/10+1)), "summary": .object(summary)])
        }
        return .object(["pagerId": handle, "items": .array(rows), "placeholdersBefore": .integer(0), "placeholdersAfter": .integer(0), "itemCount": .integer(60), "totalPages": .integer(6), "refresh": .object(["status": .string("NotLoading")])])
    }
    private var thread: JSONValue {
        func nodes(_ text: String) -> JSONValue { .array([.object(["type":.string("p"),"inlines":.array([.object(["type":.string("t"),"text":.string(text)])])])]) }
        func row(_ i: Int) -> JSONValue { .object(["commentId":.integer(Int64(i+100)),"floor":.string("#\(i)"),"authorUid":.integer(123),"authorName":.string("Reader"),"createdAtText":.string("5 min"),"nodes":nodes(i == 0 ? "Opening body" : "Reply body \(i)"),"categoryTitle":.string("Tech"),"isMine":.bool(false)]) }
        return .object(["title":.string("Diagnostic thread"),"body":row(0),"comments":.array((1...12).map(row)),"commentPages":.array((1...12).map { _ in .integer(1) }),"firstLoadedPage":.integer(1),"lastLoadedPage":.integer(1),"totalPages":.integer(1),"collected":.bool(false),"collectionCount":.integer(0)])
    }
    func revoke() {
        revoked = true
        session?.yield(.object(["identityEpoch": .string("B"), "isSignedIn": .bool(false), "generation": .integer(2)]))
        boundary?.yield(.object(["identityEpoch": .string("B"), "phase": .string("READY"), "requiresConfirmation": .bool(false), "recoveryEligible": .bool(false)]))
        for c in feeds { c.yield(feed(.string("late-A"))) }
    }
}
