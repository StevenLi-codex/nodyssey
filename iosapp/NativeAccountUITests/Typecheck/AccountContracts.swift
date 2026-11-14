// Signature-only adapters. This check verifies SwiftUI expressions, NOT iOS/Kotlin linkage.
import SwiftUI
import NodysseyNativeCore
import UIKit

struct NativeDestination { var route: String; var arguments: [String: JSONValue] }
@MainActor final class NativeAppModel: ObservableObject {
    @Published var generation = 0
    var transport: any NativeTransport { fatalError() }
    var siteOrigin: String? { fatalError() }
    var isSignedIn: Bool { fatalError() }
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue { fatalError() }
    func open(_ route: String, _ arguments: [String: JSONValue] = [:]) { fatalError() }
    func openLink(_ url: String) { fatalError() }
    func showSignIn() { fatalError() }
}
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    func load(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async { fatalError() }
    func observe(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async { fatalError() }
    func invalidate() { fatalError() }
}
extension JSONValue {
    func nativeString(_ key: String) -> String? { self[key]?.string }
    func nativeInt(_ key: String) -> Int64? { self[key]?.int }
    func nativeBool(_ key: String) -> Bool? { self[key]?.bool }
    func nativeArray(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
    func nativeEncoded() throws -> Data { try JSONEncoder().encode(self) }
}
struct NativeFailureView: View {
    let failure: NativeFailure
    var retry: (() -> Void)? = nil
    var body: some View { EmptyView() }
}
struct NativeRemoteImage: View { let url: String; var aspectFit = true; var body: some View { EmptyView() } }
struct NativeTurnstile: View {
    var darkTheme = false
    var resetSignal = 0
    let onToken: (String) -> Void
    let onExpired: () -> Void
    let onUnavailable: () -> Void
    var body: some View { EmptyView() }
}
enum NativeBrowserGoal { case login, oneTapLogin, challenge, manage, telegramBind }
struct NativeBrowser: View {
    let url: String
    var title = ""
    var goal: NativeBrowserGoal = .login
    var onFinished: () -> Void = {}
    var body: some View { EmptyView() }
}
extension Image { init(uiImage: UIImage) { self.init(systemName: "photo") } }
enum AccountKeyboardType { case numberPad }
enum AccountAutocapitalization { case never }
extension View {
    func keyboardType(_ type: AccountKeyboardType) -> some View { self }
    func textInputAutocapitalization(_ type: AccountAutocapitalization) -> some View { self }
}
