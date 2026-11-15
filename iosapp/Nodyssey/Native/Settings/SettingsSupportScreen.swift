import SwiftUI
import NodysseyNativeCore

struct SettingsSupportScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let route: String
    @StateObject private var store = NativeStore()
    @StateObject private var metadata = NativeStore()
    @State private var revision = 0
    @State private var guide = false

    private var title: String {
        switch route {
        case "Privacy": return "about_privacy"

        case "Help": return "help_title"
        case "OpenSourceLicenses": return "settings_licenses"
        default: return "about_title"
        }
    }
    var body: some View {
        Form {
            SettingsStoreStatus(store: store) { revision += 1 }
            switch route {
            case "Privacy": privacy

            case "Help": help
            case "OpenSourceLicenses": licenses
            default: about
            }
        }
        .navigationTitle(Text(LocalizedStringKey(title)))
        .toolbar { Button("action_refresh") { revision += 1 } }
        .task(id: "\(app.generation)-\(revision)") {
            if route == "Privacy" { await metadata.load(app, "settings.metadata") }
            await store.load(app, route == "Privacy" ? "settings.privacy" : "settings.metadata")
        }
        .sheet(isPresented: $guide) { SettingsGuideScreen() }
    }

    @ViewBuilder private var about: some View {
        Section {
            if let version = store.value["label"]?.string { Text(verbatim: "Nodyssey · " + version).font(.headline) }
            settingsText("native_settings_attribution")
            settingsText("native_settings_native_adaptation").font(.footnote).foregroundStyle(.secondary)
            publicLink("about_project_home", "project")
            publicLink("about_feedback", "issues")
            publicLink("about_app_channel", "telegramChannel")
            publicLink("about_app_group", "telegramGroup")
        }
        Section {
            SettingsRouteRow(title: "about_help", route: "Help")
            SettingsRouteRow(title: "about_community", route: "AboutCommunity")
            SettingsRouteRow(title: "about_privacy", route: "Privacy")
            SettingsRouteRow(title: "about_changelog", route: "Changelog")
            SettingsRouteRow(title: "settings_licenses", route: "OpenSourceLicenses")
        }
        Section { settingsText("native_settings_updates_crash_limit").font(.footnote).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var privacy: some View {
        Section {
            SettingsStoreStatus(store: metadata) { revision += 1 }
            if let raw = metadata.value["terms"]?.string, let url = URL(string: raw),
               url.scheme == "https", url.user == nil, url.password == nil {
                Link(destination: url) { Text("privacy_open_original") }
            }
        }
        if let title = store.value["title"]?.string {
            Section {
                Text(verbatim: title).font(.headline)
                if let date = store.value["effectiveDate"]?.string { Text(verbatim: date).font(.caption) }
                settingsText("native_settings_privacy_provenance").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array((store.value["blocks"]?.array ?? []).enumerated()), id: \.offset) { _, block in
                switch block["type"]?.string {
                case "Heading": Text(verbatim: block["text"]?.string ?? "").font(.headline).accessibilityAddTraits(.isHeader)
                case "Paragraph": Text(verbatim: block["text"]?.string ?? "").textSelection(.enabled)
                case "ListBlock":
                    ForEach(Array((block["items"]?.array?.compactMap(\.string) ?? []).enumerated()), id: \.offset) { index, text in
                        Text(verbatim: (block["ordered"]?.bool == true ? "\(index + 1). " : "• ") + text).textSelection(.enabled)
                    }
                default: settingsText("native_settings_document_unknown").foregroundStyle(.secondary)
                }
            }
        }
    }


    @ViewBuilder private var help: some View {
        Section("help_section_confusing") {
            Text("help_native_title").font(.headline)
            Text("help_native_body")
            settingsText("native_settings_help_navigation")
        }
        Section("help_section_home") {
            Text("action_sort").font(.headline)
            settingsText("native_settings_content_limits")
            settingsText("native_settings_help_library")
            SettingsRouteRow(title: "native_settings_bookmarks", route: "Bookmarks")
            SettingsRouteRow(title: "keywords_block_title", route: "TitleKeywords", arguments: ["alerts": .bool(false)])
        }
        Section("help_section_composer") {
            settingsText("native_settings_help_editor")
            SettingsRouteRow(title: "native_settings_image_host", route: "ImageHost")
            SettingsRouteRow(title: "native_settings_stickers", route: "StickerManage")
        }
        Section {
            Button("help_replay") { guide = true }
            publicLink("about_project_home", "help")
            publicLink("about_feedback", "issues")
        }
    }

    @ViewBuilder private var licenses: some View {
        Section("licenses_app_section") {
            settingsText("native_settings_attribution")
            Text(verbatim: "GNU General Public License v3.0")
            settingsText("native_settings_no_warranty")
            publicLink("about_project_home", "project")
            publicLink("settings_licenses", "license")
            DisclosureGroup { Text(verbatim: SettingsLicenseText.gpl).font(.footnote).textSelection(.enabled) } label: { settingsText("native_settings_full_license") }
        }
        Section("licenses_dependencies_section") {
            ForEach(Array((store.value["licenses"]?.array ?? []).enumerated()), id: \.offset) { _, license in
                if let name = license["name"]?.string {
                    VStack(alignment: .leading) {
                        if let raw = license["url"]?.string, let url = URL(string: raw), url.scheme == "https" {
                            Link(destination: url) { Text(verbatim: name) }
                        } else { Text(verbatim: name) }
                        if let value = license["license"]?.string { Text(verbatim: value).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            Text("licenses_lockfile_note").font(.footnote).foregroundStyle(.secondary)
            settingsText("native_settings_swift_dependencies").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func publicLink(_ title: String, _ key: String) -> some View {
        if let raw = store.value[key]?.string, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil {
            Link(destination: url) { settingsText(title) }
        }
    }
}

private struct SettingsGuideScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var action = SettingsAction()
    @State private var page = 0
    private let titles = ["onboarding_welcome_title", "onboarding_home_title", "native_settings_bookmarks", "onboarding_composer_title", "settings_title"]
    private let bodies = ["native_settings_guide_welcome", "native_settings_help_navigation", "native_settings_help_library", "native_settings_help_editor", "native_settings_guide_settings"]
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                SettingsActionStatus(action: action)
                Spacer()
                settingsText(titles[page]).font(.title).multilineTextAlignment(.center)
                settingsText(bodies[page]).multilineTextAlignment(.center)
                Text(verbatim: "\(page + 1) / \(titles.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if page > 0 { Button("action_back") { page -= 1 }.disabled(action.busy) }
                Button(LocalizedStringKey(page == titles.count - 1 ? "onboarding_done" : "onboarding_next")) {
                    if page < titles.count - 1 { page += 1 } else { finish() }
                }.buttonStyle(.borderedProminent).disabled(action.busy)
            }.padding()
                .toolbar { Button("onboarding_skip") { finish() }.disabled(action.busy) }
        }.modifier(SettingsLifecycle(action: action))
    }
    private func finish() {
        action.run(app, "settings.set", ["key": .string("onboardingSeen"), "value": .bool(true)]) { app.settings = $0; dismiss() }
    }
}
