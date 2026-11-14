import SwiftUI
import NodysseyNativeCore

@MainActor
enum NativeSettingsScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        switch destination.route {
        case "Settings": return AnyView(SettingsHomeScreen())
        case "ThemeSettings": return AnyView(SettingsThemeScreen())
        case "DynamicColor": return AnyView(SettingsWallpaperScreen())
        case "NotificationSettings": return AnyView(SettingsNotificationScreen())
        case "ProxySettings": return AnyView(SettingsProxyScreen())
        case "DohSettings": return AnyView(SettingsDohScreen())
        case "NetworkCheck": return AnyView(SettingsNetworkScreen())
        case "Changelog": return AnyView(SettingsChangelogScreen())
        case "AboutApp", "Privacy", "Help", "OpenSourceLicenses":
            return AnyView(SettingsSupportScreen(route: destination.route))
        case "TitleKeywords":
            return AnyView(SettingsKeywordsScreen(alerts: destination.arguments["alerts"]?.bool == true))
        default: return nil
        }
    }
}

private struct SettingsHomeScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = SettingsAction()
    @StateObject private var capability = NativeStore()
    @StateObject private var site = NativeStore()
    @StateObject private var cache = NativeStore()
    @State private var clearCache = false
    @State private var revision = 0

    var body: some View {
        Form {
            SettingsActionStatus(action: action)
            SettingsStoreStatus(store: capability) { revision += 1 }
            Section {
                SettingsStoreStatus(store: site) { revision += 1 }
                if let selected = site.value["selected"]?.string {
                    Picker(selection: Binding(get: { selected }, set: { value in
                        action.run(app, "site.select", ["site": .string(value)]) { site.value = $0 }
                    })) {
                        ForEach(site.value["sites"]?.array ?? [], id: \.settingsIdentity) { row in
                            if let id = row["id"]?.string, let name = row["displayName"]?.string {
                                Text(verbatim: name).tag(id)
                            }
                        }
                    } label: { Text("action_switch_site") }
                    .disabled(action.busy)
                    settingsText("native_settings_site_restart").font(.footnote).foregroundStyle(.secondary)
                    if site.value["requiresRestart"]?.bool == true {
                        settingsText("native_settings_site_pending").foregroundStyle(.orange)
                    }
                }
            }
            Section("settings_appearance") {
                SettingsRouteRow(title: "settings_theme", route: "ThemeSettings")
                SettingsChoice(action: action, key: "appLanguage", title: "settings_language", choices: [
                    ("SYSTEM", "settings_language_system"), ("SIMPLIFIED_CHINESE", "settings_language_zh_hans"),
                    ("TRADITIONAL_CHINESE", "settings_language_zh_hant"), ("ENGLISH", "settings_language_en")
                ])
                if let scale = app.settings["fontScale"]?.settingsDouble {
                    VStack(alignment: .leading) {
                        Text("settings_body_size")
                        SettingsFontControl(action: action, value: scale)
                    }
                }
                SettingsToggle(action: action, key: "einkMode", title: "settings_eink")
                // Only Foundation's implemented consumers belong here. Unsupported reading controls
                // are explained, not exposed as persistence-only switches.
                settingsText("native_settings_reading_limits").font(.footnote).foregroundStyle(.secondary)
            }
            Section("settings_content") {
                settingsText("native_settings_content_limits").font(.footnote).foregroundStyle(.secondary)
                if capability.value["imagesOnWifiOnly"]?.bool == true {
                    SettingsToggle(action: action, key: "imagesOnWifiOnly", title: "settings_wifi_images")
                }
                SettingsToggle(action: action, key: "showBlockedContent", title: "native_settings_show_blocked")
                SettingsRouteRow(title: "keywords_block_title", route: "TitleKeywords", arguments: ["alerts": .bool(false)])
                SettingsRouteRow(title: "native_settings_account_preferences", route: "AccountPreferences")
                SettingsRouteRow(title: "native_settings_bookmarks", route: "Bookmarks")
                SettingsRouteRow(title: "native_settings_history", route: "ReadHistory")
                if let limit = app.settings["readHistoryLimit"]?.int {
                    Picker(selection: Binding(get: { limit }, set: { action.setting(app, "readHistoryLimit", .integer($0)) })) {
                        Text("history_limit_unlimited").tag(Int64(Int32.max))
                        ForEach([Int64(100), 300, 1000], id: \.self) { Text(verbatim: String($0)).tag($0) }
                        if ![100, 300, 1000, Int64(Int32.max)].contains(limit) { Text(verbatim: String(limit)).tag(limit) }
                    } label: { Text("history_limit_title") }
                    .disabled(action.busy)
                    Text("history_limit_body").font(.footnote).foregroundStyle(.secondary)
                }
                SettingsStoreStatus(store: cache) { revision += 1 }
                if let bytes = cache.value["sizeBytes"]?.int {
                    LabeledContent { Text(verbatim: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) } label: { Text("settings_clear_cache") }
                }
                Button("settings_clear_cache", role: .destructive) { clearCache = true }.disabled(action.busy)
            }
            Section("settings_network") {
                SettingsRouteRow(title: "notify_settings_title", route: "NotificationSettings")
                SettingsRouteRow(title: "proxy_title", route: "ProxySettings")
                SettingsRouteRow(title: "doh_title", route: "DohSettings")
                SettingsRouteRow(title: "network_check_title", route: "NetworkCheck")
                SettingsRouteRow(title: "native_settings_image_host", route: "ImageHost")
                SettingsRouteRow(title: "native_settings_stickers", route: "StickerManage")
                settingsText("native_settings_clipboard_limit").font(.footnote).foregroundStyle(.secondary)
            }
            Section { SettingsRouteRow(title: "settings_about_app", route: "AboutApp") }
        }
        .navigationTitle("settings_title")
        .task(id: "\(app.generation)-\(revision)") {
            async let capabilities: Void = capability.load(app, "settings.capabilities")
            async let sites: Void = site.load(app, "site.get")
            async let bytes: Void = cache.load(app, "cache.size")
            _ = await (capabilities, sites, bytes)
        }
        .confirmationDialog(Text("settings_clear_cache"), isPresented: $clearCache) {
            Button("settings_clear_cache", role: .destructive) {
                action.run(app, "cache.clear") { cache.value = $0 }
            }
            Button("action_cancel", role: .cancel) {}
        } message: { settingsText("native_settings_cache_confirmation") }
        .modifier(SettingsLifecycle(action: action))
    }
}

private struct SettingsFontControl: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var action: SettingsAction
    let value: Double
    @State private var draft = 1.0
    var body: some View {
        VStack(alignment: .leading) {
            Slider(value: $draft, in: 0.85...1.5, step: 0.05, onEditingChanged: { editing in
                if !editing { action.setting(app, "fontScale", .number(draft)) }
            }).disabled(action.busy).accessibilityLabel(Text("settings_body_size"))
            Text("settings_text_preview").font(.system(size: 17 * draft))
        }.onAppear { draft = value }.onChange(of: value) { draft = $0 }
    }
}

extension JSONValue {
    var settingsIdentity: String { self["id"]?.string ?? self["name"]?.string ?? "" }
    var settingsDouble: Double? {
        switch self { case .number(let v): return v; case .integer(let v): return Double(v); default: return nil }
    }
}
