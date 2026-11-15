// Signature-only coordination contract. Never linked or executed in production/tests.
import SwiftUI
import NodysseyNativeCore
@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport
    @Published var generation = 0
    var isSignedIn: Bool { fatalError("signature only") }
    init(transport: any NativeTransport) { self.transport = transport }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) { fatalError("signature only") }
    func openLink(_ url: String) { fatalError("signature only") }
    func showSignIn() { fatalError("signature only") }
    func registerDismissal(destinationID: UUID, close: @escaping @MainActor () async -> Bool,
                           revoke: @escaping @MainActor () -> Void,
                           terminate: @escaping @MainActor () -> Void = {},
                           validate: @escaping @MainActor () -> Bool = { true }) -> UUID { fatalError("signature only") }
    func request(_ op: String, _ args: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("signature only") }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    func load(_ app: NativeAppModel, _ op: String, _ args: [String: JSONValue] = [:]) async { fatalError("signature only") }
    func observe(_ app: NativeAppModel, _ op: String, _ args: [String: JSONValue] = [:]) async { fatalError("signature only") }
}
struct NativeDestination { let route: String; let arguments: [String: JSONValue] }
private struct NativeDestinationIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var nativeDestinationID: UUID? {
        get { self[NativeDestinationIDKey.self] }
        set { self[NativeDestinationIDKey.self] = newValue }
    }
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
struct NativeEmptyView: View {
    init(_ title: String) { }
    var body: some View { EmptyView() }
}
