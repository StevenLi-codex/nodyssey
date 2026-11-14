import SwiftUI
import NodysseyNativeCore

@MainActor
final class SettingsAction: ObservableObject {
    @Published private(set) var busy = false
    @Published var failure: NativeFailure?
    private var gate = SettingsRequestGate()
    private var task: Task<Void, Never>?

    func run(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:],
             receive: @escaping (JSONValue) -> Void = { _ in }) {
        guard let token = gate.begin() else { return }
        busy = true
        failure = nil
        let generation = app.generation
        task = Task { @MainActor in
            do {
                let result = try await app.request(operation, arguments)
                guard gate.finish(token) else { return }
                busy = false
                guard !Task.isCancelled, generation == app.generation else { return }
                receive(result)
            } catch {
                guard gate.finish(token) else { return }
                busy = false
                guard !Task.isCancelled, generation == app.generation else { return }
                failure = error as? NativeFailure ?? NativeFailure(code: "UNKNOWN", message: "")
            }
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        gate.invalidate()
        busy = false
        failure = nil
    }
    func setting(_ app: NativeAppModel, _ key: String, _ value: JSONValue) {
        run(app, "settings.set", ["key": .string(key), "value": value]) { app.settings = $0 }
    }
}

struct SettingsActionStatus: View {
    @ObservedObject var action: SettingsAction
    var body: some View {
        if action.busy { ProgressView() }
        if let failure = action.failure { NativeFailureView(failure: failure) }
    }
}

struct SettingsLifecycle: ViewModifier {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var action: SettingsAction
    func body(content: Content) -> some View {
        content.onDisappear { action.cancel() }.onChange(of: app.generation) { _ in action.cancel() }
    }
}

func settingsText(_ key: String) -> Text {
    Text(LocalizedStringKey(key), tableName: key.hasPrefix("native_settings_") ? "Settings" : nil)
}

struct SettingsRouteRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let title: String
    let route: String
    var arguments: [String: JSONValue] = [:]
    var body: some View {
        Button { app.open(route, arguments) } label: {
            HStack {
                settingsText(title)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.foregroundStyle(.primary)
        }
    }
}

struct SettingsChoice: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var action: SettingsAction
    let key: String
    let title: String
    let choices: [(String, String)]
    var body: some View {
        if let selected = app.settings[key]?.string {
            Picker(selection: Binding(get: { selected }, set: { action.setting(app, key, .string($0)) })) {
                ForEach(choices, id: \.0) { option in settingsText(option.1).tag(option.0) }
                if !choices.contains(where: { $0.0 == selected }) { Text(verbatim: selected).tag(selected) }
            } label: { settingsText(title) }
            .disabled(action.busy)
        }
    }
}

struct SettingsToggle: View {
    @EnvironmentObject private var app: NativeAppModel
    @ObservedObject var action: SettingsAction
    let key: String
    let title: String
    var body: some View {
        if let value = app.settings[key]?.bool {
            Toggle(isOn: Binding(get: { value }, set: { action.setting(app, key, .bool($0)) })) { settingsText(title) }
                .disabled(action.busy)
        }
    }
}

struct SettingsStoreStatus: View {
    @ObservedObject var store: NativeStore
    let retry: () -> Void
    var body: some View {
        if store.isLoading { ProgressView() }
        if let failure = store.failure { NativeFailureView(failure: failure, retry: retry) }
    }
}
