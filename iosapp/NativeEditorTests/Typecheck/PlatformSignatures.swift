import SwiftUI
import NodysseyNativeCore
// SIGNATURE ONLY for macOS CLT. Not included in any application or test target.
@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport
    @Published var generation = 0
    @Published var settings: JSONValue = .null
    @Published var session: JSONValue = .null
    init(transport: any NativeTransport) { self.transport = transport }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) {}
    func openLink(_ url: String) {}
    func register(_ store: NativeStore) {}
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("Signature only") }
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
@MainActor final class EditorFocus: ObservableObject { func handoff(_ action: () -> Void) { action() }; func refocus() {} }
struct MarkedTextEditor: View {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String
    var body: some View { EmptyView() }
}
struct EditorPhotoPicker: View {
    let onFile: (URL) -> Void
    let onFailure: (NativeFailure) -> Void
    var body: some View { EmptyView() }
}
