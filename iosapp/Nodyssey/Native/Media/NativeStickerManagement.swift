import SwiftUI
import NodysseyNativeCore
import UniformTypeIdentifiers

struct NativeStickerManageScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var retry = 0
    @State private var importing = false
    @State private var importText: String?
    @State private var confirmImport = false
    @State private var exporting = false
    @State private var document = MediaTextDocument()
    @State private var importResult: JSONValue = .null
    private var groups: [MediaStickerGroup] { MediaStickerGroup.groups(store.value) }

    var body: some View {
        List {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if store.isLoading { ProgressView() }
            MediaFeedback(action: action)
            Section(MediaL.text("groups")) {
                ForEach(groups) { group in
                    HStack {
                        Button { app.open("StickerGroup", ["key": .string(group.id)]) } label: {
                            HStack(spacing: 12) {
                                if let first = group.entries.first {
                                    if let url = first.url {
                                        NativeRemoteImage(url: url, aspectFit: true).frame(width: 44, height: 44).allowsHitTesting(false)
                                    } else { Text(first.insertion).font(.title2).frame(width: 44, height: 44) }
                                } else { Image(systemName: "face.smiling").frame(width: 44, height: 44).foregroundStyle(.secondary) }
                                Text(MediaL.text(group.name))
                                Spacer()
                                Text("\(group.entries.count)").foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Toggle(MediaL.text("hidden"), isOn: Binding(get: { group.hidden }, set: { hidden(group, $0) })).labelsHidden()
                            .accessibilityLabel(MediaL.text("hidden") + " " + MediaL.text(group.name))
                    }
                }.onMove { indices, destination in
                    var keys = groups.map(\.id); keys.move(fromOffsets: indices, toOffset: destination)
                    action.request(app, "stickers.groups.reorder", ["keys": .array(keys.map(JSONValue.string))])
                }
            }.disabled(action.busy)
            Section {
                Button(MediaL.text("addStickers")) { app.open("StickerAdd") }
                Button(MediaL.text("subscriptions")) { app.open("StickerSources") }
                Button(MediaL.text("hosts")) { app.open("ImageHost") }
                Button(MediaL.text("probeMine")) { action.request(app, "stickers.probeMine") }
            }.disabled(action.busy)
            if let cdn = store.value["cdn"], cdn != .null { MediaCDNSettings(snapshot: cdn) }
            Section(MediaL.text("backup")) {
                Button(MediaL.text("exportBackup")) {
                    action.request(app, "stickers.export", refresh: nil) { result in
                        if let text = result["text"]?.string { document = MediaTextDocument(text: text); exporting = true }
                    }
                }
                Button(MediaL.text("importBackup")) { importing = true }
                Text(MediaL.text("backupHelp")).font(.caption).foregroundStyle(.secondary)
                if importResult != .null {
                    if let count = importResult["stickers"]?.int { Text(MediaL.text("importedStickers") + ": \(count)") }
                    if let count = importResult["folders"]?.int { Text(MediaL.text("importedFolders") + ": \(count)") }
                    ForEach(importResult["failedRepos"]?.array?.compactMap(\.string) ?? [], id: \.self) { slug in
                        Label(slug, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }.disabled(action.busy)
            MediaUploadQueue(snapshot: store.value)
        }
        .navigationTitle(MediaL.text("stickers"))
        .toolbar { EditButton() }
        .task(id: "\(app.generation)-\(retry)") { await store.observe(app, "stickers.observe") }
        .onDisappear { action.cancel() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                importText = text; confirmImport = true
            } catch { action.failure = NativeFailure(code: "INVALID_BACKUP", message: "Could not read backup.") }
        }
        .confirmationDialog(MediaL.text("importConfirm"), isPresented: $confirmImport, titleVisibility: .visible) {
            Button(MediaL.text("importBackup")) {
                guard let importText else { return }
                action.request(app, "stickers.import", ["text": .string(importText)]) { importResult = $0; self.importText = nil }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "nodyssey-stickers") { result in
            if case .failure = result { action.failure = NativeFailure(code: "FILE_WRITE", message: "Could not export backup.") }
        }
    }
    private func hidden(_ group: MediaStickerGroup, _ value: Bool) {
        if let slug = group.slug, let path = group.path {
            action.request(app, "stickers.folders.hidden", ["slug": .string(slug), "path": .string(path), "hidden": .bool(value)])
        } else { action.request(app, "stickers.groups.hidden", ["key": .string(group.id), "hidden": .bool(value)]) }
    }
}

private struct MediaCDNSettings: View {
    let snapshot: JSONValue
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = MediaAction()
    @State private var cdn = "JSDELIVR"
    @State private var customBase = ""
    @State private var measured: [String: String] = [:]
    var body: some View {
        Section(MediaL.text("cdn")) {
            Picker(MediaL.text("cdn"), selection: $cdn) {
                Text("jsDelivr").tag("JSDELIVR")
                Text("GitHub Raw").tag("GITHUB_RAW")
                Text(MediaL.text("custom")).tag("CUSTOM")
            }
            if cdn == "CUSTOM" { TextField(MediaL.text("cdnBase"), text: $customBase).autocorrectionDisabled() }
            Button(MediaL.text("save")) { action.request(app, "stickers.cdn", ["cdn": .string(cdn), "customBase": .string(customBase)]) }
            Button(MediaL.text("measure")) {
                let selection = cdn
                action.request(app, "stickers.measure", ["cdn": .string(selection)], refresh: nil) { value in
                    measured[selection] = value["elapsedMillis"]?.int.map { "\($0) ms" } ?? MediaL.text("unreachable")
                }
            }.disabled(cdn == "CUSTOM" && (snapshot["customBase"]?.string != customBase || snapshot["effective"]?.string != "CUSTOM"))
            if let result = measured[cdn] { Text(result).font(.caption) }
            Text(MediaL.text("effective") + ": " + (snapshot["effective"]?.string ?? "")).font(.caption).foregroundStyle(.secondary)
            MediaFeedback(action: action)
        }.disabled(action.busy)
        .onAppear { cdn = snapshot["cdn"]?.string ?? "JSDELIVR"; customBase = snapshot["customBase"]?.string ?? "" }
        .onDisappear { action.cancel() }
    }
}

struct NativeStickerSourcesScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var unsubscribe: String?
    @State private var confirm = false
    @State private var retry = 0
    private var sources: [MediaRows] { MediaRows.from(store.value["subscriptions"]?.array ?? [], key: "slug") }
    var body: some View {
        List {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if store.isLoading { ProgressView() }
            MediaFeedback(action: action)
            ForEach(sources) { source in
                Section {
                    Text(source.id).font(.headline)
                    if let sha = source.value["pinnedSha"]?.string { Text(sha).font(.caption.monospaced()).textSelection(.enabled) }
                    if let ref = source.value["ref"]?.string { Text(ref).font(.caption) }
                    if source.value["hasUpdate"]?.bool == true {
                        Button(MediaL.text("applyUpdate") + " +\(source.value["newCount"]?.int ?? 0)") {
                            action.request(app, "stickers.applyUpdate", ["slug": .string(source.id)])
                        }
                    }
                    let folders = MediaRows.from(source.value["folders"]?.array ?? [], key: "path")
                    ForEach(folders) { folder in
                        Toggle(folder.value["name"]?.string ?? folder.id, isOn: Binding(get: { folder.value["hidden"]?.bool != true }, set: {
                            action.request(app, "stickers.folders.hidden", ["slug": .string(source.id), "path": .string(folder.id), "hidden": .bool(!$0)])
                        }))
                    }.onMove { indices, destination in
                        var paths = folders.map(\.id); paths.move(fromOffsets: indices, toOffset: destination)
                        action.request(app, "stickers.folders.reorder", ["slug": .string(source.id), "paths": .array(paths.map(JSONValue.string))])
                    }
                    ForEach(MediaRows.from(store.value["sourceErrors"]?.array ?? [], key: "slug").filter { $0.id == source.id }) { error in
                        MediaSourceError(value: error.value["error"] ?? .null)
                    }
                    Button(MediaL.text("changeFolders")) { app.open("StickerAdd", ["tab": .string("GITHUB"), "source": .string(source.id)]) }
                    Button(MediaL.text("unsubscribe"), role: .destructive) { unsubscribe = source.id; confirm = true }
                }.disabled(action.busy)
            }
            if sources.isEmpty && !store.isLoading { Text(MediaL.text("noSubscriptions")) }
            Button(MediaL.text("subscribe")) { app.open("StickerAdd", ["tab": .string("GITHUB")]) }
            Button(MediaL.text("checkUpdates")) {
                action.request(app, "stickers.checkUpdates", ["force": .bool(true)]) { result in
                    if let error = result["error"], error != .null { action.notice = MediaL.text("partialUpdateFailure") }
                    else { action.notice = MediaL.text("checkedUpdates") }
                }
            }.disabled(action.busy)
        }
        .navigationTitle(MediaL.text("subscriptions"))
        .toolbar { EditButton() }
        .task(id: "\(app.generation)-\(retry)") { await store.observe(app, "stickers.observe") }
        .onDisappear { action.cancel() }
        .confirmationDialog(MediaL.text("unsubscribeConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(MediaL.text("unsubscribe"), role: .destructive) {
                if let unsubscribe { action.request(app, "stickers.unsubscribe", ["slug": .string(unsubscribe)]) }
            }
        }
    }
}

struct MediaSourceError: View {
    let value: JSONValue
    var body: some View {
        VStack(alignment: .leading) {
            Label(MediaL.text(value["type"]?.string ?? "sourceError"), systemImage: "exclamationmark.triangle")
            if let code = value["code"]?.int { Text("HTTP \(code)") }
            if let reset = value["resetAtEpochSeconds"]?.int {
                Text(Date(timeIntervalSince1970: TimeInterval(reset)), style: .relative)
            }
        }.font(.caption).foregroundStyle(.red)
    }
}

struct MediaUploadQueue: View {
    let snapshot: JSONValue
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = MediaAction()
    var body: some View {
        let uploads = MediaRows.from(snapshot["uploads"]?.array ?? [], key: "id")
        if !uploads.isEmpty {
            Section(MediaL.text("uploads")) {
                ForEach(uploads) { row in
                    VStack(alignment: .leading) {
                        Text(row.value["name"]?.string ?? "")
                        Text(MediaL.text(row.value["state"]?.string ?? "queued")).font(.caption)
                        if case .number(let progress) = row.value["progress"], progress.isFinite { ProgressView(value: min(max(progress, 0), 1)) }
                        if let error = row.value["error"]?.string {
                            NativeFailureView(failure: NativeFailure(code: error, message: "Upload failed."))
                            Button(MediaL.text("retry")) { action.request(app, "stickers.retryUpload", ["id": .string(row.id)]) }
                        }
                    }
                }
                Button(MediaL.text("clearFinished")) { action.request(app, "stickers.clearFinishedUploads") }
                MediaFeedback(action: action)
            }.disabled(action.busy)
            .onDisappear { action.cancel() }
        }
    }
}
