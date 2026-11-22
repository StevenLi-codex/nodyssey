import SwiftUI

/// One neutral palette for routed pages and the canvas below native navigation.
/// Reading cards stay opaque; system bars keep their own material and scroll edges.
struct NativePageSurface: View {
    @Environment(\.colorScheme) private var scheme
    var canvas = false

    var body: some View {
        (scheme == .dark
            ? (canvas ? Color(.sRGB, white: 0.035, opacity: 1) : Color(.sRGB, white: 0.085, opacity: 1))
            : (canvas ? Color(.sRGB, white: 0.95, opacity: 1) : Color.white))
    }
}

extension View {
    /// Extend only the canvas, never the scroll content or its keyboard safe area.
    /// A custom View background otherwise ends at the TabView/NavigationStack inset,
    /// exposing a different system canvas beside the floating native tab material.
    func nativePageCanvas() -> some View {
        background {
            NativePageSurface(canvas: true)
                .ignoresSafeArea(.container)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NativeClearNavigationBar: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // The older toolbarBackground(.hidden) no longer removes the glass
            // band on iOS 26, so the bar kept painting a tinted strip over the
            // page canvas. Visibility is the API that actually clears it.
            content.toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        } else {
            content.toolbarBackground(.hidden, for: .navigationBar)
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Leave the navigation bar as the bare glass island so page content shows
    /// through the rest of the strip.
    func nativeClearNavigationBar() -> some View { modifier(NativeClearNavigationBar()) }
}
