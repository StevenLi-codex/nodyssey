import SwiftUI
import NodysseyNativeCore
#if canImport(UIKit)
import UIKit
import PhotosUI
import ImageIO
#endif

struct SettingsThemeScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = SettingsAction()
    @State private var hex = ""
    @State private var name = ""
    @State private var deleteColor: Int64?
    #if canImport(UIKit)
    @State private var photo: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var photoFailure = false
    #endif

    var body: some View {
        Form {
            SettingsActionStatus(action: action)
            Section("settings_theme_mode") {
                SettingsChoice(action: action, key: "themeMode", title: "settings_theme_mode", choices: [
                    ("SYSTEM", "settings_theme_system"), ("LIGHT", "settings_theme_light"), ("DARK", "settings_theme_dark")
                ])
                if app.settings["einkMode"]?.bool == true { Text("settings_theme_eink_hint").foregroundStyle(.secondary) }
            }
            Section("settings_color_source") {
                SettingsChoice(action: action, key: "colorSource", title: "settings_color_source", choices: [
                    ("PRESET", "settings_color_source_preset"), ("CUSTOM", "settings_color_source_custom")
                ])
                SettingsRouteRow(title: "settings_dynamic_color", route: "DynamicColor")
            }
            Section("settings_color_source_preset") {
                SettingsChoice(action: action, key: "presetId", title: "settings_color_source_preset", choices: [
                    ("graphite", "settings_preset_graphite"), ("miku", "settings_preset_miku"), ("twins", "settings_preset_twins"),
                    ("tianyi", "settings_preset_tianyi"), ("reimu", "settings_preset_reimu"), ("marisa", "settings_preset_marisa")
                ])
            }
            Section("settings_seed_sheet_title") {
                TextField("settings_seed_hex", text: $hex).autocorrectionDisabled()
                if let argb = SettingsColor.argb(hex) {
                    settingsColor(argb).frame(height: 40).accessibilityLabel(Text(verbatim: hex))
                }
                #if canImport(UIKit)
                ColorPicker("settings_seed_edit", selection: Binding(get: {
                    settingsColor(SettingsColor.argb(hex) ?? app.settings["seedColor"]?.int ?? -16777216)
                }, set: { color in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
                        hex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
                    } else {
                        action.failure = NativeFailure(code: "INVALID_DATA", message: "Could not convert selected color")
                    }
                }), supportsOpacity: false).disabled(action.busy)
                PhotosPicker(selection: $photo, matching: .images) { Text("settings_seed_pick_from_image") }
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 240)
                    settingsText("native_settings_photo_eyedropper").font(.footnote)
                }
                if photoFailure { settingsText("native_settings_photo_failed").foregroundStyle(.red) }
                #endif
                Button("action_save") {
                    if let color = SettingsColor.argb(hex) { action.setting(app, "seedColor", .integer(color)) }
                }.disabled(action.busy || SettingsColor.argb(hex) == nil)
                settingsText("native_settings_custom_source_hint").font(.footnote).foregroundStyle(.secondary)
                TextField("settings_seed_name", text: $name)
                Button("settings_seed_save") {
                    if let color = SettingsColor.argb(hex) {
                        action.run(app, "settings.theme.save", ["name": .string(name), "color": .integer(color)]) { app.settings = $0 }
                    }
                }.disabled(action.busy || SettingsColor.argb(hex) == nil)
            }
            Section("settings_palette_style") {
                SettingsChoice(action: action, key: "paletteStyle", title: "settings_palette_style", choices: [
                    ("SOFT", "settings_palette_style_soft"), ("MONOCHROME", "settings_palette_style_monochrome")
                ])
                settingsText("native_settings_palette_limits").font(.footnote).foregroundStyle(.secondary)
            }
            Section("settings_my_themes") {
                ForEach(Array((app.settings["savedThemes"]?.array ?? []).enumerated()), id: \.offset) { _, theme in
                    if let color = theme["color"]?.int {
                        HStack {
                            settingsColor(color).frame(width: 28, height: 28).clipShape(Circle())
                            Button {
                                hex = SettingsColor.hex(color)
                                name = theme["name"]?.string ?? ""
                                action.setting(app, "seedColor", .integer(color))
                            } label: {
                                Text(verbatim: (theme["name"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsColor.hex(color))
                            }
                            Spacer()
                            Button(role: .destructive) { deleteColor = color } label: { Image(systemName: "trash") }
                                .accessibilityLabel(Text("action_delete"))
                        }.disabled(action.busy)
                    }
                }
            }
            Section("settings_theme_preview") {
                Text("settings_theme_preview_title").font(.headline)
                Text("settings_theme_preview_meta").foregroundStyle(.secondary)
                Label("settings_theme_preview_accent", systemImage: "paintpalette.fill").foregroundStyle(.tint)
            }
        }
        .navigationTitle("settings_theme")
        .onAppear { if hex.isEmpty, let color = app.settings["seedColor"]?.int { hex = SettingsColor.hex(color) } }
        .confirmationDialog(Text("action_delete"), isPresented: Binding(get: { deleteColor != nil }, set: { if !$0 { deleteColor = nil } })) {
            Button("action_delete", role: .destructive) {
                if let color = deleteColor {
                    action.run(app, "settings.theme.delete", ["color": .integer(color)]) { app.settings = $0 }
                }
                deleteColor = nil
            }
            Button("action_cancel", role: .cancel) { deleteColor = nil }
        }
        #if canImport(UIKit)
        .task(id: photo) {
            guard let photo else { return }
            photoFailure = false
            do {
                guard let data = try await photo.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024
                      ] as CFDictionary) else { photoFailure = true; return }
                guard !Task.isCancelled else { return }
                preview = UIImage(cgImage: image)
            } catch { if !Task.isCancelled { photoFailure = true } }
        }
        .onDisappear { photo = nil; preview = nil }
        #endif
        .modifier(SettingsLifecycle(action: action))
    }
}

private func settingsColor(_ argb: Int64) -> Color {
    let rgb = UInt32(truncatingIfNeeded: argb)
    return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}

struct SettingsWallpaperScreen: View {
    var body: some View {
        Form {
            Section { settingsText("native_settings_wallpaper_limit") }
            SettingsRouteRow(title: "settings_seed_sheet_title", route: "ThemeSettings")
        }.navigationTitle("settings_dynamic_color")
    }
}
