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
        VStack(spacing: 0) {
            HStack {
                Text("p\(fixture.profileReads) n\(fixture.notificationStarts) f\(fixture.feedStarts) r\(fixture.notificationRefreshes)").accessibilityIdentifier("requests")
                Button("Revoke") { fixture.revoke() }.accessibilityIdentifier("revoke")
                Menu("Control") {
                    Button("Same") { fixture.emit(change: false) }
                    Button("Change") { fixture.emit(change: true) }
                    Button("Empty") { fixture.releaseEmpty() }
                    Button("Release") { fixture.releaseRows() }
                    Button("Fail") { fixture.fail() }
                    Button("Late") { fixture.late() }
                }.accessibilityIdentifier("control")
                Text("e\(fixture.emissions)").accessibilityIdentifier("emissions")
            }.font(.caption)
            if ProcessInfo.processInfo.arguments.contains("--anchor-probe") { FixtureAnchorRoot() }
            else { NativeRootView() }
        }.environmentObject(app).environmentObject(fixture)
            .overlay(alignment: .topLeading) { RetentionGeometryProbe().frame(width: 1, height: 1).allowsHitTesting(false) }
            .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-profile") ? .accessibility2 : .large)
    } }
}
// Real NativeRootView, NativeAppModel, NativeStore, NativeRequestState and root
// screen declarations compile together. Only non-root destinations/image/theme
// and the Kotlin/network boundary are replaced; no production fixture hooks.
struct FixtureDestination: View { let name: String; var body: some View { Text("Destination " + name).accessibilityIdentifier("destination").navigationTitle("Detail") } }
enum NativeAccountScreens { static func make(destination: NativeDestination) -> AnyView? { destination.route == "Profile" ? AnyView(AccountProfileScreen()) : nil } }
enum NativeEditorScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
enum NativeLibraryScreens { static func make(destination: NativeDestination) -> AnyView? { AnyView(FixtureDestination(name: destination.route)) } }
enum NativeSettingsScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
enum NativeMediaScreens { static func make(destination: NativeDestination) -> AnyView? { nil } }
struct NativeExternalBrowser: View { let url: URL; var body: some View { EmptyView() } }
struct NativeSettingsAppearance: ViewModifier { let settings: JSONValue; func body(content: Content) -> some View { content } }
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
struct ContentPostDetail: View { let postID: Int64; let initialFloor: String?; let initialPage: Int64?; let preview: JSONValue?; var body: some View { FixtureDestination(name: "PostDetail") } }
struct ContentBoardManager: View { let categories: JSONValue; @Binding var selection: String; var body: some View { EmptyView() } }

enum AccountAuthorQuickCardNavigation { case signIn; case route(String, [String: JSONValue]) }
struct AccountAuthorQuickCard: View { let uid: Int64; let onNavigate: (AccountAuthorQuickCardNavigation) -> Void; var body: some View { Text("Author card") } }

// Additional synthetic parent exercises the shipping ContentPagedList with a
// saved post absent from a replacement page; main tests keep actual NativeRootView.
struct FixtureAnchorRoot: View {
    @State private var page: Int64 = 4
    @State private var hide = false
    @State private var observed: Int64 = 0
    var body: some View {
        VStack {
            HStack {
                Button("Page 10") { page = 10 }
                Button("Hide feed") { hide.toggle() }
                Text("observed \(observed)").accessibilityIdentifier("observed-page")
            }
            TabView(selection: $hide) {
                NavigationStack {
                    ContentPagedList(operation: "feed", arguments: ["sort": .string("LAST_REPLY"), "page": .integer(page)],
                                     restoreID: 42, replacePage: { page = $0 }, visible: { _, value in observed = value ?? 0 })
                }.tag(false).tabItem { Text("Feed") }
                Text("Hidden feed").tag(true).tabItem { Text("Other") }
            }
        }
    }
}
@MainActor final class FixtureTransport: ObservableObject, NativeTransport {
    @Published var profileReads = 0
    @Published var notificationStarts = 0
    @Published var feedStarts = 0
    @Published var notificationRefreshes = 0
    private var session: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var boundary: AsyncThrowingStream<JSONValue, Error>.Continuation?
    private var feeds: [(AsyncThrowingStream<JSONValue, Error>.Continuation, [String: JSONValue])] = []
    private var notifications: [AsyncThrowingStream<JSONValue, Error>.Continuation] = []
    @Published var emissions = 0
    private var changed = -1
    private var hold: Bool { ProcessInfo.processInfo.arguments.contains("--hold-notifications") }
    private var notificationRows: JSONValue {
        .array((0..<60).map { i in
            .object(["id": .string("n\(i)"), "sourceId": .integer(Int64(i+1)), "sources": .array([.object(["id": .string("n\(i)"), "category": .string("REPLIES")])]), "category": .string("REPLIES"), "actorUid": .integer(123), "actorName": .string(i == changed ? "Edited" : "Reader"), "threadTitle": .string("Notification \(i)"), "createdAtText": .string("Notification \(i)"), "postId": .integer(Int64(i+1)), "isReply": .bool(true), "isUnread": .bool(i != changed)])
        })
    }
    var revoked = false
    private var profile: JSONValue { .object(["uid": .integer(123), "name": .string("Retained reader"), "chickenCount": .integer(234), "starCount": .integer(12), "rank": .integer(5)]) }
    private var site: JSONValue { .object(["current": .string("DEEPFLOOD"), "selected": .string("DEEPFLOOD"), "requiresRestart": .bool(false), "sites": .array([.object(["id": .string("DEEPFLOOD"), "origin": .string("https://www.deepflood.com"), "displayName": .string("Fixture")])])]) }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        switch operation {
        case "site.get": return site
        case "profile.self": profileReads += 1; return profile
        case "attendance.status": return .object(["uid": .integer(123), "date": .string("2026-11-16"), "hasSignedIn": .bool(true), "gain": .integer(14)])
        case "notifications.refresh": notificationRefreshes += 1; return .null
        case "paging.access", "paging.refresh", "categories.refresh", "app.foreground", "boards.recent.record", "notifications.read", "messages.refresh": return .null
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
            case "settings.observe": continuation.yield(.object(["onboardingSeen": .bool(true), "homePageBar": .bool(true)]))
            case "profile.self": continuation.yield(profile)
            case "categories": continuation.yield(.array([.object(["slug": .string("board-b"), "title": .string("Board B")])]))
            case "boards.recent", "messages.list": continuation.yield(.array([]))
            case "notifications.counts": continuation.yield(.object(["interactions": .integer(40), "messages": .integer(0)]))
            case "notifications.list":
                notificationStarts += 1
                notifications.append(continuation)
                if !hold || notificationStarts > 1 { continuation.yield(notificationRows) }
            case "feed":
                feedStarts += 1; feeds.append((continuation, arguments))
                let handle = arguments["pagerId"] ?? .string("fixture")
                let loading: JSONValue = .object(["pagerId": handle, "items": .array([]), "refresh": .object(["status": .string("Loading")])])
                continuation.yield(loading)
                let snapshot = feed(handle, arguments)
                if !ProcessInfo.processInfo.arguments.contains("--hold-feed") {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        continuation.yield(snapshot) // Deliberate late callback for revocation test.
                    }
                }
            default: continuation.finish(throwing: NativeFailure(code: "BOUNDARY", message: operation))
            }
        }
    }
    private func feed(_ handle: JSONValue, _ arguments: [String: JSONValue] = [:]) -> JSONValue {
        let start = Int(max(1, arguments["page"]?.int ?? 1) - 1) * 10
        let prefix = arguments["categorySlug"]?.string == "board-b" ? "BoardB " : "Post "
        let rows: [JSONValue] = (start..<(start+60)).map { i in
            let summary: [String: JSONValue] = ["postId": .integer(9007199254741001 + Int64(i)), "authorUid": .integer(123), "authorName": .string("Author \(i)"), "title": .string(prefix + String(i)), "categoryTitle": .string("Board"), "commentCount": .integer(i == changed ? 13 : 12), "viewCount": .integer(345), "lastActiveText": .string("5 min")]
            return .object(["page": .integer(Int64(i/10+1)), "summary": .object(summary)])
        }
        return .object(["pagerId": handle, "items": .array(rows), "placeholdersBefore": .integer(0), "placeholdersAfter": .integer(0), "itemCount": .integer(60), "totalPages": .integer(20), "refresh": .object(["status": .string("NotLoading")])])
    }
    func emit(change: Bool) {
        if change { changed += 1 }
        for (c, args) in feeds { c.yield(feed(args["pagerId"] ?? .string("fixture"), args)) }
        for c in notifications { c.yield(notificationRows) }
        emissions += 1
    }
    func releaseEmpty() { for c in notifications { c.yield(.array([])) }; emissions += 1 }
    func releaseRows() { emit(change: false) }
    func fail() { for c in notifications { c.finish(throwing: NativeFailure(code: "NETWORK", message: "Fixture failure")) } }
    func late() {
        for (c, args) in feeds { c.yield(feed(.string("late-A"), args)) }
        for c in notifications { c.yield(notificationRows) }
        emissions += 1
    }
    func revoke() {
        revoked = true
        session?.yield(.object(["identityEpoch": .string("B"), "isSignedIn": .bool(false), "generation": .integer(2)]))
        boundary?.yield(.object(["identityEpoch": .string("B"), "phase": .string("READY"), "requiresConfirmation": .bool(false), "recoveryEligible": .bool(false)]))
        late()
    }
}
