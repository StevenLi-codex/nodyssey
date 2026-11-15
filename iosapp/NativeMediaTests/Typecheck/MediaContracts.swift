// Compile-only app/platform boundaries. Never linked into the application or executed.
import SwiftUI
import NodysseyNativeCore

@MainActor final class NativeAppModel: ObservableObject {
    var generation: UInt64 { fatalError("signature only") }
    var transport: any NativeTransport { fatalError("signature only") }
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("signature only") }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) { fatalError("signature only") }
}
@MainActor final class NativeStore: ObservableObject {
    var value: JSONValue { fatalError("signature only") }
    var failure: NativeFailure? { fatalError("signature only") }
    var isLoading: Bool { fatalError("signature only") }
    func observe(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async { fatalError("signature only") }
}
struct NativeRemoteImage: View {
    let url: String
    var aspectFit = true
    var body: some View { EmptyView() }
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
// EditButton is iOS-only, and this existing screen retains it for group reordering.
struct EditButton: View { var body: some View { EmptyView() } }
struct NativeImageGallery: View {
    let urls: [String]
    var initialIndex = 0
    var body: some View { EmptyView() }
}
