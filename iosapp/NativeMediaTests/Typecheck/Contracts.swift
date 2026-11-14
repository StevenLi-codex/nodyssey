// Signature-only fixtures for macOS SwiftUI typechecking. Never linked into production.
import SwiftUI
import NodysseyNativeCore
struct EditButton: View { var body: some View { EmptyView() } } // iOS-only system control signature
struct NativeDestination { let route: String; let arguments: [String: JSONValue] }
@MainActor final class NativeAppModel: ObservableObject {
    var transport: any NativeTransport { fatalError("Signature only") }
    @Published var generation = 0
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) {}
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError("Signature only") }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    func load(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async {}
    func observe(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async {}
}
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)? = nil; var body: some View { EmptyView() } }
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
struct NativeImageGallery: View { let urls: [String]; let initialIndex: Int; var body: some View { EmptyView() } }
enum NativeBrowserGoal { case login, oneTapLogin, challenge, manage, telegramBind }
struct NativeBrowser: View { let url: String; let title: String; let goal: NativeBrowserGoal; var body: some View { EmptyView() } }
