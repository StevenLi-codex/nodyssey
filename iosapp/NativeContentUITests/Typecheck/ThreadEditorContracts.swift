// CLT signature-only boundary for the cross-domain thread/reply presentation.
// The actual Editor, Account quick card and Content sources are compiled together.
import SwiftUI
import NodysseyNativeCore

enum NativeTab { case home, notifications, profile }
extension NativeDestination { var id: UUID { fatalError("Signature fixture") } }
extension NativeAppModel {
    var transport: any NativeTransport { fatalError("Signature fixture") }
    var site: JSONValue { fatalError("Signature fixture") }
    var siteName: String? { fatalError("Signature fixture") }
    var selectedTab: NativeTab { fatalError("Signature fixture") }
    var homePath: [NativeDestination] { fatalError("Signature fixture") }
    var notificationsPath: [NativeDestination] { fatalError("Signature fixture") }
    var profilePath: [NativeDestination] { fatalError("Signature fixture") }
    var sheetPath: [NativeDestination] { fatalError("Signature fixture") }
    var sheet: NativeDestination? { fatalError("Signature fixture") }
    var departureRunning: Bool { fatalError("Signature fixture") }
    func registerDismissal(destinationID: UUID, close: @escaping @MainActor () async -> Bool,
                           revoke: @escaping @MainActor () -> Void,
                           terminate: @escaping @MainActor () -> Void = {},
                           validate: @escaping @MainActor () -> Bool = { true }) -> UUID { fatalError("Signature fixture") }
    func dismissDestination(_ id: UUID) async { fatalError("Signature fixture") }
}
extension EnvironmentValues {
    var nativeDestinationID: UUID? {
        get { fatalError("Signature fixture") }
        set { fatalError("Signature fixture") }
    }
}
@MainActor final class EditorFocus: ObservableObject { func handoff(_ action: () -> Void) { fatalError("Signature fixture") }; func refocus() { fatalError("Signature fixture") } }
struct MarkedTextEditor: View {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    var accessibilityLabel: String
    var autofocus = false
    var body: some View { EmptyView() }
}
struct EditorPhotoPicker: View { let model: EditorViewModel; var body: some View { EmptyView() } }
// Media-owned picker contract; its implementation is checked by the media gate.
struct NativeStickerPicker: View { let onSelect: (String) -> Void; var body: some View { EmptyView() } }
