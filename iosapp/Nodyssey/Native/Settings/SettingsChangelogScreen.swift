import SwiftUI
import NodysseyNativeCore

/// Read-only project history. This never calls app update/download/install operations.
struct SettingsChangelogScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @State private var previewReleases = false
    @State private var revision = 0
    @State private var releases: [SettingsReleaseNotes]?
    @State private var parseFailure: NativeFailure?

    var body: some View {
        List {
            Section {
                settingsText("native_settings_release_scope").font(.footnote).foregroundStyle(.secondary)
                Toggle(isOn: $previewReleases) { settingsText("native_settings_release_include_preview") }
            }
            SettingsStoreStatus(store: store) { revision += 1 }
            if let parseFailure { NativeFailureView(failure: parseFailure, retry: { revision += 1 }) }
            if let releases {
                if releases.isEmpty { Text("changelog_empty").foregroundStyle(.secondary) }
                ForEach(releases) { release in
                    NavigationLink {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(verbatim: release.version).font(.title)
                                Text(verbatim: release.published).font(.subheadline).foregroundStyle(.secondary)
                                if release.preRelease { Text("about_update_prerelease").font(.caption) }
                                if release.text.isEmpty { Text("changelog_no_notes").foregroundStyle(.secondary) }
                                else { Text(verbatim: release.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                if let url = release.url { Link("about_update_open_release", destination: url) }
                            }.padding()
                        }.navigationTitle(Text(verbatim: release.version))
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: release.version).font(.headline)
                            Text(verbatim: release.published).font(.caption).foregroundStyle(.secondary)
                            if release.preRelease { Text("about_update_prerelease").font(.caption) }
                        }
                    }
                }
            }
        }
        .navigationTitle("about_changelog")
        .toolbar { Button("changelog_refresh") { revision += 1 }.disabled(store.isLoading) }
        .task(id: "\(app.generation)-\(revision)-\(previewReleases)") {
            releases = nil
            parseFailure = nil
            await store.load(app, "settings.changelog", ["includePreRelease": .bool(previewReleases)])
            guard !Task.isCancelled, store.failure == nil else { return }
            do { releases = try SettingsReleaseNotes.decode(store.value) }
            catch { parseFailure = error as? NativeFailure ?? NativeFailure(code: "INVALID_DATA", message: "") }
        }
    }
}
