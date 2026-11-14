import SwiftUI
import NodysseyNativeCore
#if canImport(UIKit)
import UIKit
import UserNotifications
#endif

struct SettingsNotificationScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionKey = "native_settings_permission_unknown"
    var body: some View {
        Form {
            Section { settingsText("native_settings_notification_limit") }
            Section {
                LabeledContent { settingsText(permissionKey) } label: { settingsText("native_settings_system_permission") }
                #if canImport(UIKit)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: { settingsText("native_settings_open_system_settings") }
                #endif
                settingsText("native_settings_permission_not_delivery").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                SettingsRouteRow(title: "keywords_alert_title", route: "TitleKeywords", arguments: ["alerts": .bool(true)])
                SettingsRouteRow(title: "notify_tracked_threads", route: "TrackedThreads")
                SettingsRouteRow(title: "notify_telegram_title", route: "AccountContact")
                Text("notify_telegram_body").font(.footnote)
                SettingsRouteRow(title: "notify_settings_title", route: "Notifications")
            }
        }.navigationTitle("notify_settings_title")
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { phase in if phase == .active { Task { await refreshPermission() } } }
    }
    private func refreshPermission() async {
        #if canImport(UIKit)
        let value = await UNUserNotificationCenter.current().notificationSettings()
        switch value.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permissionKey = "native_settings_permission_allowed"
        case .denied: permissionKey = "native_settings_permission_denied"
        case .notDetermined: permissionKey = "native_settings_permission_unasked"
        @unknown default: permissionKey = "native_settings_permission_unknown"
        }
        #endif
    }
}

struct SettingsKeywordsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    let alerts: Bool
    @StateObject private var store = NativeStore()
    @StateObject private var action = SettingsAction()
    @State private var regex = false
    @State private var text = ""
    @State private var revision = 0
    private var kind: String { alerts ? "ALERT" : regex ? "BLOCK_REGEX" : "BLOCK" }

    var body: some View {
        Form {
            SettingsStoreStatus(store: store) { revision += 1 }
            SettingsActionStatus(action: action)
            if alerts { settingsText("native_settings_notification_limit").font(.footnote) }
            else { Text("keywords_block_footer").font(.footnote) }
            Section {
                if !alerts { Toggle("keywords_regex_toggle", isOn: $regex).disabled(action.busy) }
                TextField(LocalizedStringKey(regex ? "keywords_regex_placeholder" : "keywords_add_placeholder"), text: $text)
                    .autocorrectionDisabled()
                Button("keywords_add_action") {
                    action.run(app, "keywords.add", ["kind": .string(kind), "text": .string(text)]) {
                        store.value = $0; text = ""
                    }
                }.disabled(action.busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section {
                if store.value.array?.isEmpty == true { Text("keywords_empty").foregroundStyle(.secondary) }
                ForEach(store.value.array?.compactMap(\.string) ?? [], id: \.self) { keyword in
                    HStack {
                        Text(verbatim: keyword).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            action.run(app, "keywords.remove", ["kind": .string(kind), "text": .string(keyword)]) { store.value = $0 }
                        } label: { Image(systemName: "trash") }.accessibilityLabel(Text("action_delete"))
                    }.disabled(action.busy)
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(alerts ? "keywords_alert_title" : "keywords_block_title")))
        .task(id: "\(app.generation)-\(kind)-\(revision)") {
            await store.observe(app, "keywords.observe", ["kind": .string(kind)])
        }
        .onChange(of: kind) { _ in action.cancel(); text = ""; store.invalidate() }
        .modifier(SettingsLifecycle(action: action))
    }
}
