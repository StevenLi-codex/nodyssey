import SwiftUI
import NodysseyNativeCore

@main struct HomeRowProbe: App {
    @StateObject private var app = NativeAppModel()
    var body: some Scene { WindowGroup { Host().environmentObject(app) } }
}
struct Host: View {
    @EnvironmentObject var app: NativeAppModel
    var body: some View {
        NavigationStack {
            ContentPagedList(operation: "feed", arguments: ["page": .integer(1)], replacePage: { _ in })
                .navigationTitle("Production feed")
                .safeAreaInset(edge: .top) {
                    Text(app.event).accessibilityIdentifier("event")
                }
        }.dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large") ? .accessibility2 : .large)
    }
}
@MainActor final class NativeAppModel: ObservableObject {
    @Published var generation = 1
    @Published var settings: JSONValue = .null
    @Published var event = "none"
    var site: JSONValue = .null
    var siteName: String? = "Fixture"
    var isSignedIn = false
    let transport: any NativeTransport = FixtureTransport()
    func register(_ store: NativeStore) {}
    func open(_ route: String, _ args: [String: JSONValue] = [:]) {
        event = route + ":" + String(args["postId"]?.int ?? args["uid"]?.int ?? 0)
    }
    func showSignIn() { event = "signIn" }
    func request(_ operation: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await transport.request(operation, args)
    }
}
struct FixtureTransport: NativeTransport {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        guard operation == "paging.access" else { throw NativeFailure(code: "BOUNDARY", message: "No network or writes: " + operation) }
        return .null
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            guard operation == "feed" else { continuation.finish(); return }
            let rows: [JSONValue] = (0..<30).map { index -> JSONValue in
                let title: String = index == 1 ? "Long title wraps across several lines with enough words to exercise the production row layout" : "Post \(index)"
                let postID: Int64 = 9007199254741001 + Int64(index)
                let authorID: Int64 = 9007199254741101 + Int64(index)
                let summary: [String: JSONValue] = [
                    "postId": .integer(postID), "authorUid": .integer(authorID),
                    "authorName": .string("Author \(index)"), "title": .string(title),
                    "categoryTitle": .string("Board"), "commentCount": .integer(12), "viewCount": .integer(345),
                    "lastCommenterName": .string("Reader"), "lastActiveText": .string("5 min"), "isPinned": .bool(index == 2)
                ]
                return .object(["page": .integer(Int64(index / 10 + 1)), "summary": .object(summary)])
            }
            continuation.yield(.object(["pagerId": arguments["pagerId"] ?? .string("fixture"), "placeholdersBefore": .integer(0), "placeholdersAfter": .integer(0), "itemCount": .integer(30), "totalPages": .integer(3), "items": .array(rows), "refresh": .object(["status": .string("NotLoading")])]))
        }
    }
}
// Explicit non-feed destination/image boundaries. No network, auth or storage.
struct NativeDestination { let route: String; let arguments: [String: JSONValue] }
struct ContentNotifications: View { let initialGroup: String?; var body: some View { EmptyView() } }
struct ContentPostDetail: View { let postID: Int64; let initialFloor: String?; let initialPage: Int64?; let preview: JSONValue?; var body: some View { EmptyView() } }
struct ContentBoardManager: View { let categories: JSONValue; @Binding var selection: String; var body: some View { EmptyView() } }
enum AccountAuthorQuickCardNavigation { case signIn; case route(String, [String: JSONValue]) }
struct AccountAuthorQuickCard: View {
    @EnvironmentObject var app: NativeAppModel
    @Environment(\.dismiss) var dismiss
    let uid: Int64
    let onNavigate: (AccountAuthorQuickCardNavigation) -> Void
    var body: some View { VStack { Text("Author card \(uid)").accessibilityIdentifier("author-card"); Button("Close card") { dismiss() } }.onAppear { app.event = "Author:\(uid)" } }
}
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)? = nil; var body: some View { Text(failure.message) } }
struct NativeEmptyView: View { init(_ title: String) {}; var body: some View { EmptyView() } }
struct NativeBusyView: View { var body: some View { ProgressView() } }
struct NativeRemoteImage: View { let url: String; var aspectFit: Bool = true; var body: some View { EmptyView() } }
extension JSONValue {
    func nativeString(_ key: String) -> String? { self[key]?.string }
    func nativeInt(_ key: String) -> Int64? { self[key]?.int }
    func nativeBool(_ key: String) -> Bool? { self[key]?.bool }
    func nativeArray(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
}
