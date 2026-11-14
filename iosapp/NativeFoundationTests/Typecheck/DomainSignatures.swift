// Compile-only signatures. Not shipped, not runtime behavior, not iOS linkage proof.
import SwiftUI
@MainActor enum NativeContentScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
#if !FOUNDATION_EDITOR_UI_CHECK
@MainActor enum NativeEditorScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
#endif
@MainActor enum NativeAccountScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
@MainActor enum NativeLibraryScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
@MainActor enum NativeSettingsScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
@MainActor enum NativeMediaScreens { static func make(destination: NativeDestination) -> AnyView? { fatalError("signature only") } }
struct NativeExternalBrowser: View {
    let url: URL
    var body: some View { EmptyView() }
}
