// Executable test boundaries only. Not shipping code, not a Kotlin parser or platform test.
import SwiftUI
import NodysseyNativeCore

struct NativeDestination { let route: String; let arguments: [String: JSONValue] }
@MainActor final class NativeAppModel: ObservableObject {
    @Published var generation = 0
    @Published var session: JSONValue = .null
    @Published var settings: JSONValue = .null
    var isSignedIn: Bool { false }
    var parseCalls: [[String: JSONValue]] = []
    var unexpectedOperations: [String] = []
    var sourceLeaves: [UUID: NativeCodeBlock] = [:]
    var routes: [(String, [String: JSONValue])] = []
    var links: [String] = []
    func open(_ route: String, _ args: [String: JSONValue] = [:]) { routes.append((route, args)) }
    func openLink(_ url: String) { links.append(url) }
    func showSignIn() { fatalError("Unexpected sign in") }
    func request(_ operation: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard operation == "reports.parse" else {
            unexpectedOperations.append(operation)
            throw NativeFailure(code: "UNEXPECTED_TEST_OPERATION", message: operation)
        }
        parseCalls.append(args)
        // Synthetic parser result. This tests routing/policy, never report recognition.
        if args["code"]?.string == "ordinary" { return .null }
        return .object(["title": .string("Synthetic report"), "sections": .array([]), "footnotes": .array([])])
    }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    func load(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:]) async {
        isLoading = true
        defer { isLoading = false }
        do { value = try await app.request(operation, args) }
        catch { failure = error as? NativeFailure }
    }
    func observe(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:]) async { fatalError("Unexpected observation") }
    func invalidate() { fatalError("Unexpected invalidation") }
}
// Observe which source leaves the real report policy mounts, not text labels/screenshots.
struct NativeCodeBlock: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var identity = UUID()
    let code: NativeCode
    var actions: NativeRichTextActions = .init()
    var body: some View {
        Color.clear.frame(height: 1)
            .onAppear { app.sourceLeaves[identity] = self }
            .onDisappear { app.sourceLeaves[identity] = nil }
    }
}
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)? = nil; var body: some View { Text(failure.code) } }
struct NativeEmptyView: View { init(_ title: String) {}; var body: some View { EmptyView() } }
struct NativeBusyView: View { var body: some View { ProgressView() } }
struct NativeRemoteImage: View {
    let url: String
    var aspectFit: Bool = true
    var body: EmptyView { return unavailable() }
    private func unavailable() -> EmptyView { fatalError("Unexpected image load: \(url)") }
}
extension JSONValue {
    func nativeString(_ key: String) -> String? { self[key]?.string }
    func nativeInt(_ key: String) -> Int64? { self[key]?.int }
    func nativeBool(_ key: String) -> Bool? { self[key]?.bool }
    func nativeArray(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
    func nativeEncoded() throws -> Data { try JSONEncoder().encode(self) }
}
