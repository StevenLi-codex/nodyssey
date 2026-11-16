import SwiftUI

/// Theme tint is composited over an opaque surface, never applied to body text.
/// Hairlines keep the hierarchy legible when transparency or contrast is restricted.
struct ContentThreadOpeningBand: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var prominent = false

    private var tintOpacity: Double {
        if reduceTransparency || contrast == .increased { return prominent ? 0.10 : 0.04 }
        return prominent ? (scheme == .dark ? 0.14 : 0.085) : (scheme == .dark ? 0.07 : 0.035)
    }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, prominent ? 14 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ContentSurface().overlay { Rectangle().fill(.tint).opacity(tintOpacity) }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.primary.opacity(contrast == .increased ? 0.25 : 0.07)).frame(height: 0.5)
                    .allowsHitTesting(false)
            }
    }
}
