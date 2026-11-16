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
        runReadback(app, operation, arguments, readback: { $0 }, receive: receive)
    }

    private func runReadback(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue],
                             readback: @escaping (JSONValue) async throws -> JSONValue,
                             receive: @escaping (JSONValue) -> Void) {
        guard let token = gate.begin() else { return }
        busy = true
        failure = nil
        let generation = app.generation
        task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                guard generation == app.generation else { throw CancellationError() }
                var result = try await app.request(operation, arguments)
                try Task.checkCancellation()
                guard generation == app.generation else { throw CancellationError() }
                result = try await readback(result)
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
        let themeKeys = ["seedColor", "presetId", "colorSource", "themeMode", "paletteStyle"]
        guard themeKeys.contains(key) else {
            run(app, "settings.set", ["key": .string(key), "value": value]) { app.settings = $0 }
            return
        }
        let generation = app.generation
        runReadback(app, "settings.set", ["key": .string(key), "value": value], readback: { receipt in
            guard receipt[key] == value else {
                throw NativeFailure(code: "INVALID_DATA", message: "Theme preference was not persisted")
            }
            // The shared repository deliberately retains a seed/preset independently
            // of its source. Choosing one in this screen means applying it as well.
            let source = key == "seedColor" ? "CUSTOM" : key == "presetId" ? "PRESET" : nil
            if let source, receipt["colorSource"]?.string != source {
                try Task.checkCancellation()
                guard generation == app.generation else { throw CancellationError() }
                let selected = try await app.request("settings.set", ["key": .string("colorSource"), "value": .string(source)])
                guard selected["colorSource"]?.string == source else {
                    throw NativeFailure(code: "INVALID_DATA", message: "Theme source was not persisted")
                }
            }
            try Task.checkCancellation()
            guard generation == app.generation else { throw CancellationError() }
            let snapshot = try await app.request("settings.get")
            guard snapshot[key] == value, source == nil || snapshot["colorSource"]?.string == source else {
                throw NativeFailure(code: "INVALID_DATA", message: "Theme readback did not match selection")
            }
            return snapshot
        }) { app.settings = $0 }
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

private struct NativeSettingsAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var nativeSettingsAccent: Color {
        get { self[NativeSettingsAccentKey.self] }
        set { self[NativeSettingsAccentKey.self] = newValue }
    }
}

struct SettingsChoice: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.nativeSettingsAccent) private var accent
    @ScaledMetric(relativeTo: .body) private var menuVerticalInset: CGFloat = 7
    @ObservedObject var action: SettingsAction
    let key: String
    let title: String
    let choices: [(String, String)]
    var body: some View {
        if let selected = app.settings[key]?.string {
            let selectedLabel = choices.first(where: { $0.0 == selected }).map { settingsText($0.1) }
                ?? Text(verbatim: selected)
            LabeledContent {
                // The automatic Picker label on iOS retains its initial UIKit tint,
                // even with a changing local .tint. Keep Apple's menu/selection
                // behavior, but render the closed value in SwiftUI. Remove this
                // split when the automatic label follows live theme changes.
                Menu {
                    Picker(selection: Binding(get: { selected }, set: { action.setting(app, key, .string($0)) })) {
                        ForEach(choices, id: \.0) { option in settingsText(option.1).tag(option.0) }
                        if !choices.contains(where: { $0.0 == selected }) { Text(verbatim: selected).tag(selected) }
                    } label: { settingsText(title) }
                } label: {
                    HStack {
                        selectedLabel
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }.foregroundStyle(accent)
                        // Restore the automatic Picker's content insets without
                        // fixing its total height; the semantic text still grows.
                        .padding(.vertical, menuVerticalInset)
                        .padding(.horizontal, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settingsText(title))
                .accessibilityValue(selectedLabel)
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
