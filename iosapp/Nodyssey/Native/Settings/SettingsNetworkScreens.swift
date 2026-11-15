import SwiftUI
import NodysseyNativeCore

struct SettingsProxyScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = SettingsAction()
    @State private var draft = SettingsProxyDraft(snapshot: .null)
    @State private var loaded = false
    @State private var result: JSONValue = .null
    @State private var revision = 0

    private var canTest: Bool {
        loaded && store.value["enabled"]?.bool == true && store.value["isUsable"]?.bool == true &&
        (try? draft.payload()) == (try? SettingsProxyDraft(snapshot: store.value).payload())
    }

    var body: some View {
        Form {
            SettingsStoreStatus(store: store) { revision += 1 }
            SettingsActionStatus(action: action)
            if loaded {
                Section {
                    Toggle(isOn: Binding(get: { store.value["enabled"]?.bool == true }, set: { enabled in
                        result = .null
                        action.run(app, "proxy.enabled", ["enabled": .bool(enabled)]) { store.value = $0 }
                    })) { Text("proxy_master_title") }
                    Text("proxy_master_hint").font(.footnote).foregroundStyle(.secondary)
                }.disabled(action.busy)
                Section("proxy_title") {
                    Picker("proxy_type_title", selection: $draft.type) {
                        Text("proxy_type_http").tag("HTTP")
                        Text("proxy_type_socks").tag("SOCKS")
                    }
                    TextField("proxy_host_label", text: $draft.host).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    TextField("proxy_port_label", text: $draft.port).autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    TextField("proxy_username_label", text: $draft.username).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("proxy_password_label", text: Binding(get: { draft.password }, set: {
                        draft.password = $0; draft.passwordChanged = true
                    }))
                    if store.value["hasPassword"]?.bool == true { settingsText("native_settings_secret_preserved").font(.footnote) }
                    Button(role: .destructive) { draft.password = ""; draft.passwordChanged = true } label: { settingsText("native_settings_clear_password") }
                    Toggle("proxy_scope_title", isOn: Binding(get: { draft.scope == "FORUM_ONLY" }, set: { draft.scope = $0 ? "FORUM_ONLY" : "EVERYTHING" }))
                    Text("proxy_scope_hint").font(.footnote).foregroundStyle(.secondary)
                    Button("proxy_save") {
                        do {
                            let payload = try draft.payload()
                            draft.password = ""; draft.passwordChanged = false
                            result = .null
                            action.run(app, "proxy.save", payload) { saved in
                                store.value = saved
                                draft = SettingsProxyDraft(snapshot: saved)
                            }
                        } catch { action.failure = error as? NativeFailure }
                    }.disabled((try? draft.payload()) == nil)
                }.disabled(action.busy)
                Section {
                    if draft != SettingsProxyDraft(snapshot: store.value) {
                        settingsText("native_settings_unsaved").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("proxy_test") {
                        result = .null
                        action.run(app, "proxy.test") { result = $0 }
                    }.disabled(action.busy || !canTest)
                    settingsText("native_settings_test_saved").font(.footnote).foregroundStyle(.secondary)
                    if let connected = result["connected"]?.bool {
                        if connected { Label("proxy_test_success", systemImage: "checkmark.circle") }
                        else {
                            settingsText("native_settings_probe_failed").foregroundStyle(.red)
                            if let kind = result["kind"]?.string { Text(verbatim: kind).font(.caption) }
                        }
                    }
                }
            }
            Section { Text("proxy_webview_hint"); Text("proxy_advanced_hint") }
        }
        .navigationTitle("proxy_title")
        .task(id: "\(app.generation)-\(revision)") {
            loaded = false
            draft = SettingsProxyDraft(snapshot: .null)
            result = .null
            await store.load(app, "proxy.get")
            guard !Task.isCancelled, store.value.object != nil else { return }
            draft = SettingsProxyDraft(snapshot: store.value)
            loaded = true
        }
        .onChange(of: draft) { _ in result = .null }
        .onDisappear { draft.password = ""; draft.passwordChanged = false }
        .modifier(SettingsLifecycle(action: action))
    }
}

struct SettingsDohScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = SettingsAction()
    @State private var servers: [JSONValue] = []
    @State private var selected = ""
    @State private var result: JSONValue = .null
    @State private var revision = 0
    @State private var edited = false

    private var config: JSONValue { store.value["config"] ?? .null }
    private var capabilities: JSONValue { store.value["capabilities"] ?? .null }
    private var enabled: Bool { config["enabled"]?.bool == true }

    var body: some View {
        Form {
            SettingsStoreStatus(store: store) { revision += 1 }
            SettingsActionStatus(action: action)
            if config.object != nil {
                Section {
                    Toggle("doh_master_title", isOn: Binding(get: { enabled }, set: {
                        result = .null
                        action.run(app, "doh.enabled", ["enabled": .bool($0)]) { store.value = $0 }
                    })).disabled(action.busy)
                    Text("doh_master_hint").font(.footnote).foregroundStyle(.secondary)
                }
                Section("doh_provider_title") {
                    Picker("doh_provider_title", selection: Binding(get: { selected }, set: { selected = $0; edited = true; result = .null })) {
                        Text("doh_no_server").tag("")
                        ForEach(servers, id: \.settingsIdentity) { row in
                            if let id = row["id"]?.string { Text(verbatim: row["preset"]?.string ?? row["customUrl"]?.string ?? id).tag(id) }
                        }
                    }
                    ForEach(Array(servers.enumerated()), id: \.element.settingsIdentity) { index, row in
                        DisclosureGroup {
                            if row["preset"]?.string == nil {
                                TextField("doh_url_label", text: field(index, "customUrl")).autocorrectionDisabled()
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never).keyboardType(.URL)
                                    #endif
                            } else if let url = row["url"]?.string { Text(verbatim: url).textSelection(.enabled) }
                            TextField("doh_bootstrap_label", text: field(index, "bootstrapOverride")).autocorrectionDisabled()
                            if row["preset"]?.string != nil {
                                Button("doh_bootstrap_reset") { update(index, "bootstrapOverride", .null) }
                            }
                            if let addresses = row["bootstrap"]?.array {
                                Text(verbatim: addresses.compactMap(\.string).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Button("action_delete", role: .destructive) {
                                if selected == row["id"]?.string { selected = "" }
                                servers.remove(at: index); edited = true; result = .null
                            }
                        } label: { Text(verbatim: row["preset"]?.string ?? row["customUrl"]?.string ?? row.settingsIdentity) }
                    }
                    Button("doh_add_custom") {
                        servers.append(.object(["id": .string("custom-" + UUID().uuidString), "preset": .null,
                                                "customUrl": .string(""), "bootstrapOverride": .string(""), "checked": .bool(false)]))
                        edited = true
                    }
                    Button { restoreMissingPresets() } label: { settingsText("native_settings_restore_resolvers") }
                    if edited { settingsText("native_settings_unsaved").font(.footnote).foregroundStyle(.secondary) }
                    Button("doh_save") { saveServers() }.disabled(enabled && selected.isEmpty)
                }.disabled(action.busy)
                Section {
                    // Apple does not implement these switches; never mirror their persisted values
                    // as if they controlled A/AAAA or system fallback.
                    if capabilities["canChooseRecordTypes"]?.bool == false { settingsText("native_settings_record_types_limit") }
                    if capabilities["canFallBackToSystem"]?.bool == false { Text("doh_limits_encrypted_only_hint") }
                    if capabilities["triesServersInOrder"]?.bool == false { Text("doh_details_note") }
                    Text("doh_proxy_hint")
                    Text("doh_webview_hint")
                }.font(.footnote).foregroundStyle(.secondary)
                Section {
                    Button("doh_test") { result = .null; action.run(app, "doh.test") { result = $0 } }
                        .disabled(action.busy || edited || !enabled)
                    settingsText("native_settings_test_saved").font(.footnote).foregroundStyle(.secondary)
                    if let host = result["host"]?.string {
                        Text(verbatim: host).font(.headline)
                        ForEach(result["addresses"]?.array?.compactMap(\.string) ?? [], id: \.self) { Text(verbatim: $0).textSelection(.enabled) }
                        if let millis = result["elapsedMillis"]?.int { Text(verbatim: "\(millis) ms") }
                    }
                }
            }
        }
        .navigationTitle("doh_title")
        .task(id: "\(app.generation)-\(revision)") {
            servers = []; selected = ""; result = .null; edited = false
            await store.load(app, "doh.get")
            guard !Task.isCancelled else { return }
            resetDraft()
        }
        .modifier(SettingsLifecycle(action: action))
    }

    private func resetDraft() {
        servers = config["servers"]?.array ?? []
        selected = servers.first(where: { $0["checked"]?.bool == true })?["id"]?.string ?? ""
        edited = false
    }
    private func field(_ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { servers.indices.contains(index) ? servers[index][key]?.string ?? "" : "" }, set: { update(index, key, .string($0)) })
    }
    private func update(_ index: Int, _ key: String, _ value: JSONValue) {
        guard servers.indices.contains(index), var row = servers[index].object else { return }
        row[key] = value; servers[index] = .object(row); edited = true; result = .null
    }
    private func saveServers() {
        do {
            let rows: [JSONValue]
            if selected.isEmpty {
                rows = servers.map { row in var value = row.object ?? [:]; value["checked"] = .bool(false); return .object(value) }
            } else { rows = try SettingsDohSelection.select(selected, servers: servers) }
            result = .null
            action.run(app, "doh.save", ["servers": .array(rows)]) { saved in store.value = saved; resetDraft() }
        } catch { action.failure = error as? NativeFailure }
    }
    private func restoreMissingPresets() {
        for id in ["ALIDNS", "DNSPOD", "CLOUDFLARE", "GOOGLE"] where !servers.contains(where: { $0["id"]?.string == id }) {
            servers.append(.object(["id": .string(id), "preset": .string(id), "customUrl": .string(""), "bootstrapOverride": .null, "checked": .bool(false)]))
        }
        edited = true; result = .null
    }
}

struct SettingsNetworkScreen: View {
    var body: some View {
        Form {
            Section { settingsText("native_settings_diagnostics_limit") }
            Section {
                SettingsRouteRow(title: "proxy_test", route: "ProxySettings")
                SettingsRouteRow(title: "doh_test", route: "DohSettings")
                settingsText("native_settings_probe_scope").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("network_check_title")
    }
}
