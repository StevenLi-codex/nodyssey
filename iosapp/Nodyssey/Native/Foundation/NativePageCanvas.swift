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
