import SwiftUI
import NodysseyNativeCore

private struct NativeDestinationIDKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var nativeDestinationID: UUID? {
        get { self[NativeDestinationIDKey.self] }
        set { self[NativeDestinationIDKey.self] = newValue }
    }
}

struct NativeScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let destination: NativeDestination
    var body: some View {
        screen
            // Own the entire destination canvas, including navigation safe areas.
            // Individual Lists/Forms may still supply their native content surfaces.
            .nativePageCanvas()
            .environment(\.nativeDestinationID, destination.id)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("native.screen.\(destination.route)")
    }
    private var screen: AnyView {
        guard app.canDisplay(destination) else { return AnyView(NativePrivateBoundaryRecoveryView()) }
        // Explicit external URLs only: never a fallback for an unimplemented native route.
        if destination.route == "Web", destination.arguments["goal"]?.string == "EXTERNAL" {
            if let value = destination.arguments["url"]?.string,
               NativeLinkRouting.isSafeWebURL(value), let url = URL(string: value) {
                return AnyView(NativeExternalBrowser(url: url))
            }
            return AnyView(NativeFailureView(failure: NativeFailure(code: "INVALID_LINK", message: "Invalid address")))
        }
        return NativeContentScreens.make(destination: destination)
            ?? NativeEditorScreens.make(destination: destination)
            ?? NativeAccountScreens.make(destination: destination)
            ?? NativeLibraryScreens.make(destination: destination)
            ?? NativeSettingsScreens.make(destination: destination)
            ?? NativeMediaScreens.make(destination: destination)
            ?? AnyView(NativeFailureView(failure: NativeFailure(code: "UNKNOWN_ROUTE", message: "Unsupported destination")))
    }
}
