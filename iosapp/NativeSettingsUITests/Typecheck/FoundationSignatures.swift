// Signature-only CLT harness. Not linked into the app and never returns repository data.
import SwiftUI
import NodysseyNativeCore

struct NativeDestination {
    let route: String
    let arguments: [String: JSONValue]
}
@MainActor final class NativeAppModel: ObservableObject {
    @Published var settings: JSONValue = .null
    @Published var generation = 0
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("Signature only") }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) { fatalError("Signature only") }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    func load(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async { fatalError("Signature only") }
    func observe(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async { fatalError("Signature only") }
    func invalidate() { fatalError("Signature only") }
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
