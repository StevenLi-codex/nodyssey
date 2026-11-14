import SwiftUI
import NodysseyNativeCore

struct NativePreviewMenu: View {
    @EnvironmentObject private var app: NativeAppModel
    var body: some View {
        Form {
            Text("preview_guest_notice", tableName: "Foundation")
            Button { app.open("Settings") } label: { Label("Settings", systemImage: "gearshape") }
            Button { app.open("ThemeSettings") } label: { Label("Appearance", systemImage: "paintpalette") }
        }
    }
}

struct NativeScreen: View {
    let destination: NativeDestination
    var body: some View {
        screen
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("native.screen.\(destination.route)")
    }
    private var screen: AnyView {
        if destination.route == "Profile" { return AnyView(NativePreviewMenu()) }
        let allowed: Set<String> = ["PostList", "PostDetail", "Thread", "Search", "UserSpace", "Settings", "ThemeSettings", "Changelog", "AboutApp", "Privacy", "Help", "OpenSourceLicenses", "ImageViewer"]
        guard allowed.contains(destination.route) else {
            return AnyView(Text("preview_guest_notice", tableName: "Foundation").padding())
        }
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
