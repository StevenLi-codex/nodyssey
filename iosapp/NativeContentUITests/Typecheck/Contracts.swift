// Signature-only fixtures for macOS SwiftUI typechecking. Never linked into the app.
import SwiftUI
import Combine
import NodysseyNativeCore
struct NativeDestination { let route: String; let arguments: [String: JSONValue] }
@MainActor final class NativeAppModel: ObservableObject {
    let homeScrollToTop = PassthroughSubject<Void, Never>()
    @Published var generation = 0
    @Published var session: JSONValue = .null
    @Published var settings: JSONValue = .null
    var isSignedIn: Bool { false }
    func open(_ route: String, _ args: [String: JSONValue] = [:]) { fatalError("Signature fixture") }
    func openLink(_ url: String) { fatalError("Signature fixture") }
    func showSignIn() { fatalError("Signature fixture") }
    func request(_ operation: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("Signature fixture") }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    var isReplacingPagingWindow: Bool { false }
    var isRefreshing: Bool { false }
    var hasValue: Bool { false }
    @discardableResult func observeRetained(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:], restart: Int = 0) -> Bool { fatalError("Signature fixture") }
    @discardableResult func refreshRetained(_ app: NativeAppModel, _ operationName: String, _ arguments: [String: JSONValue] = [:], mode: NativeRefreshCompletionMode) async -> Bool { fatalError("Signature fixture") }
    func cancel() { fatalError("Signature fixture") }
    func observeCached(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:], maximumAge: TimeInterval = 60) async { fatalError("Signature fixture") }
    func load(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:]) async { fatalError("Signature fixture") }
    func observe(_ app: NativeAppModel, _ operation: String, _ args: [String: JSONValue] = [:]) async { fatalError("Signature fixture") }
    func invalidate() { fatalError("Signature fixture") }
}
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)? = nil; var body: some View { EmptyView() } }
struct NativeEmptyView: View { init(_ title: String) {}; var body: some View { EmptyView() } }
struct NativeBusyView: View { var body: some View { EmptyView() } }
struct NativeRemoteImage: View { let url: String; var aspectFit: Bool = true; var body: some View { EmptyView() } }
extension JSONValue {
    func nativeString(_ key: String) -> String? { self[key]?.string }
    func nativeInt(_ key: String) -> Int64? { self[key]?.int }
    func nativeBool(_ key: String) -> Bool? { self[key]?.bool }
    func nativeArray(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
    func nativeEncoded() throws -> Data { try JSONEncoder().encode(self) }
}
