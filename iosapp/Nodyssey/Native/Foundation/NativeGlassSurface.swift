import SwiftUI

/// Feed cards and chrome share an edge without changing the controls' layout.
enum NativeFeedLayout {
    static let horizontalInset: CGFloat = 12
    static let cardCornerRadius: CGFloat = 18
    static let chromeCornerRadius: CGFloat = 22

    // Use the platform's adaptive label color, not hierarchical/vibrant text
    // or the user's accent, for actionable text over the glass background.
    static var controlForeground: Color {
        #if canImport(UIKit)
        Color(uiColor: .label)
        #elseif canImport(AppKit)
        Color(nsColor: .labelColor)
        #else
        Color.primary
        #endif
    }
}

/// Decorative chrome only: keep controls and their state outside this view.
/// iOS 16–25 use system material, not a hand-drawn Liquid Glass imitation.
struct NativeGlassSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    enum Role { case regular, homeSearch }

    var cornerRadius: CGFloat = 16
    var opaque = false
    var role: Role = .regular

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        surface.allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private var surface: some View {
        if opaque || reduceTransparency || contrast == .increased {
            shape.fill(scheme == .dark ? Color(.sRGB, white: 0.085, opacity: 1) : .white)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.3 : 0.12), lineWidth: 0.5) }
        } else {
            #if os(iOS) && compiler(>=6.2)
            if #available(iOS 26.0, *) {
                if role == .homeSearch {
                    // Clear glass has no public blur/brightness tuning. This role
                    // stays over the opaque neutral feed canvas (never moving rows),
                    // with adaptive label foregrounds and no added tint or rim.
                    Color.clear.glassEffect(.clear, in: shape)
                } else {
                    Color.clear
                        .overlay { shape.fill(.tint).opacity(0.035) }
                        .glassEffect(.regular, in: shape)
                }
            } else {
                materialSurface
            }
            #else
            materialSurface
            #endif
        }
    }

    @ViewBuilder private var materialSurface: some View {
        if role == .homeSearch {
            shape.fill(.ultraThinMaterial)
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.fill(.tint).opacity(0.035) }
                .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        }
    }
}

/// Group neighbouring glass surfaces without wrapping/replacing controls when
/// theme or accessibility preferences change. No morphing IDs are needed.
struct NativeGlassContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if os(iOS) && compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Availability-only grouping leaves the controls structurally stable.
            GlassEffectContainer(spacing: 0) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
