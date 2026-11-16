import SwiftUI
import NodysseyNativeCore

/// Render shared preferences; never creates a second settings store.
private struct NativePalette {
    // Original primary tokens: designsys/theme/CharacterPalette.kt; graphite is
    // SettingsRepository.DEFAULT_SEED_COLOR. System surfaces keep native contrast.
    static let accents: [String: (UInt32, UInt32)] = [
        "graphite": (0xFF35606E, 0xFF35606E), "miku": (0xFF008078, 0xFF53D7CE),
        "twins": (0xFF8F6F00, 0xFFFFD84A), "tianyi": (0xFF1478B2, 0xFF72CEFA),
        "reimu": (0xFFBC3038, 0xFFFFB3B6), "marisa": (0xFF8A6C00, 0xFFF4D657)
    ]
}

struct NativeSettingsAppearance: ViewModifier {
    let settings: JSONValue
    @Environment(\.locale) private var systemLocale
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dynamicTypeSize) private var systemTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var eink: Bool { settings.nativeBool("einkMode") == true }
    private var scheme: ColorScheme? {
        if eink { return .light }
        switch settings.nativeString("themeMode") {
        case "LIGHT": return .light
        case "DARK": return .dark
        default: return nil
        }
    }
    private var locale: Locale {
        switch settings.nativeString("appLanguage") {
        case "SIMPLIFIED_CHINESE": return Locale(identifier: "zh-Hans")
        case "TRADITIONAL_CHINESE": return Locale(identifier: "zh-Hant")
        case "ENGLISH": return Locale(identifier: "en")
        default: return systemLocale
        }
    }
    private var accent: Color {
        let source = settings.nativeString("colorSource")
        let preset = settings.nativeString("presetId") ?? "graphite"
        // Original PlazaTheme gives character palettes precedence over seed style.
        // MONOCHROME steers only generated palettes; e-ink overrides every source.
        let character = source == "PRESET" && preset != "graphite" && NativePalette.accents[preset] != nil
        if eink || (!character && settings.nativeString("paletteStyle") == "MONOCHROME") { return .primary }
        let dark = (scheme ?? systemColorScheme) == .dark
        // Match presetById: stale catalogue IDs explicitly fall back to graphite.
        let pair = NativePalette.accents[preset] ?? NativePalette.accents["graphite"]!
        let raw: UInt32
        if settings.nativeString("colorSource") == "CUSTOM", let seed = settings.nativeInt("seedColor") {
            raw = UInt32(truncatingIfNeeded: seed)
        } else if settings.nativeString("colorSource") == "WALLPAPER", let seed = settings.nativeInt("wallpaperSeed") {
            raw = UInt32(truncatingIfNeeded: seed)
        } else { raw = dark ? pair.1 : pair.0 }
        return Color(.sRGB, red: Double((raw >> 16) & 255) / 255,
                     green: Double((raw >> 8) & 255) / 255, blue: Double(raw & 255) / 255, opacity: 1)
    }
    private var typeSize: DynamicTypeSize {
        let scale: Double
        switch settings["fontScale"] {
        case .number(let value): scale = value
        case .integer(let value): scale = Double(value)
        default: return systemTypeSize
        }
        guard scale.isFinite, scale > 0 else { return systemTypeSize }
        // Use Apple's semantic sizes rather than scaleEffect (which clips text/layout).
        // Accessibility categories are never reduced by the in-app preference.
        if systemTypeSize.isAccessibilitySize { return systemTypeSize }
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        guard let index = sizes.firstIndex(of: systemTypeSize) else { return systemTypeSize }
        let offset = Int(((min(2, max(0.5, scale)) - 1) / 0.12).rounded())
        return sizes[min(sizes.count - 1, max(0, index + offset))]
    }
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(scheme)
            .tint(accent)
            // Explicit Color.accentColor consumers (rich links, badges, paging)
            // read a different environment from TintShapeStyle/native controls.
            .accentColor(accent)
            .environment(\.locale, locale)
            .dynamicTypeSize(typeSize)
            .transaction { if reduceMotion || eink { $0.disablesAnimations = true; $0.animation = nil } }
    }
}
