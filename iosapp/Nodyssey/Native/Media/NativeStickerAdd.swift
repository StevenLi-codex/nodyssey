import SwiftUI
import PhotosUI
import QuickLook
import CoreTransferable
import UniformTypeIdentifiers
import NodysseyNativeCore

struct NativeStickerAddScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var host = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var tab: String
    let source: String?
    @State private var text = ""
    @State private var previews: [MediaLinkPreview] = []
    @State private var importingLinks = false
    @State private var showHost = false
    @State private var undoURLs: [String] = []
    @State private var retry = 0
    init(tab: String = "LINK", source: String? = nil) {
        self.source = source
        _tab = State(initialValue: source != nil ? "GITHUB" : tab)
    }
    var body: some View {
        Form {
            Picker(MediaL.text("addFrom"), selection: $tab) {
                Text(MediaL.text("links")).tag("LINK")
                Text(MediaL.text("hosts")).tag("HOST")
                Text(MediaL.text("upload")).tag("UPLOAD")
                Text("GitHub").tag("GITHUB")
            }.pickerStyle(.segmented)
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            MediaFeedback(action: action)
            switch tab {
            case "LINK": linkSection
            case "HOST": hostSection
            case "UPLOAD": MediaUploadPicker()
            case "GITHUB": MediaSubscriptionPicker(source: source, snapshot: store.value)
            default: NativeFailureView(failure: NativeFailure(code: "INVALID_ARGUMENT", message: "Unknown sticker tab."))
            }
            if !undoURLs.isEmpty {
                Button(MediaL.text("undoCollection")) {
                    action.request(app, "stickers.remove", ["urls": .array(undoURLs.map(JSONValue.string))]) { _ in undoURLs = [] }
                }.disabled(action.busy)
            }
            MediaUploadQueue(snapshot: store.value)
        }
        .navigationTitle(MediaL.text("addStickers"))
        .task(id: "\(app.generation)-\(retry)") { undoURLs = []; await store.observe(app, "stickers.observe") }
        .task(id: "\(app.generation)-\(retry)") { await host.observe(app, "imageHost.observe") }
        .onDisappear { action.cancel() }
        .fileImporter(isPresented: $importingLinks, allowedContentTypes: [.plainText, .json]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                self.text = text; previews = MediaLinkPreview.parse(text)
            } catch { action.failure = NativeFailure(code: "FILE_READ", message: "Could not read file.") }
        }
        .sheet(isPresented: $showHost) {
            if let provider = host.value["provider"]?.string {
                NavigationStack {
                    MediaHostGallery(provider: provider) { images in
                        add(images.map { .object(["url": .string($0.url), "name": .string($0.name)]) })
                    }
                }
            }
        }
    }
    private var linkSection: some View {
        Section(MediaL.text("links")) {
            TextEditor(text: $text).frame(minHeight: 100).accessibilityLabel(MediaL.text("links"))
            HStack {
                PasteButton(payloadType: String.self) { values in text = values.joined(separator: "\n"); previews = MediaLinkPreview.parse(text) }
                Button(MediaL.text("importLinks")) { importingLinks = true }
                Button(MediaL.text("preview")) { previews = MediaLinkPreview.parse(text) }
            }
            ForEach($previews) { $preview in
                HStack {
                    NativeRemoteImage(url: preview.url, aspectFit: true).frame(width: 48, height: 48)
                    VStack(alignment: .leading) {
                        TextField(MediaL.text("name"), text: $preview.name)
                        Text(preview.url).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                    }
                    Toggle(MediaL.text("select"), isOn: $preview.selected).labelsHidden()
                }
            }
            if !previews.isEmpty {
                Button(MediaL.text("addSelected")) {
                    add(previews.filter(\.selected).map { .object(["url": .string($0.url), "name": .string($0.name)]) })
                }.disabled(!previews.contains(where: { $0.selected && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            }
        }.disabled(action.busy)
    }
    private var hostSection: some View {
        Section(MediaL.text("uploaded")) {
            if let failure = host.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if let provider = host.value["provider"]?.string { Text(MediaL.text(provider)) }
            Text(MediaL.text("hostSelectHelp")).font(.caption)
            Button(MediaL.text("chooseUploaded")) { showHost = true }.disabled(host.value["isConfigured"]?.bool != true || action.busy)
            Button(MediaL.text("configureHost")) { app.open("ImageHost") }
        }
    }
    private func add(_ stickers: [JSONValue]) {
        action.request(app, "stickers.add", ["stickers": .array(stickers)]) { value in
            undoURLs = value["addedUrls"]?.array?.compactMap(\.string) ?? []
            action.notice = MediaL.text("added") + ": \(undoURLs.count)"
        }
    }
}

private struct MediaSubscriptionPicker: View {
    let source: String?
    let snapshot: JSONValue
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = MediaAction()
    @State private var url = ""
    @State private var draft = MediaSubscriptionDraft()
    @State private var initialized = false
    var body: some View {
        Section(MediaL.text("repository")) {
            TextField(MediaL.text("repositoryURL"), text: $url).autocorrectionDisabled()
                .onChange(of: url) { _ in draft.invalidate() }
            Button(MediaL.text("inspect")) {
                let inspectedURL = url
                action.request(app, "stickers.inspect", ["url": .string(inspectedURL)], refresh: nil) { listing in
                    guard inspectedURL == url else { return }
                    do {
                        try draft.accept(listing, url: inspectedURL)
                        if let source, let existing = snapshot["subscriptions"]?.array?.first(where: { $0["slug"]?.string == source }) {
                            let paths = Set(existing["folders"]?.array?.compactMap { $0["path"]?.string } ?? [])
                            draft.selected = paths.intersection(Set(draft.folders.compactMap { $0["path"]?.string }))
                        }
                    } catch { action.failure = error as? NativeFailure }
                }
            }.disabled(url.isEmpty || action.busy)
            if let sha = draft.listing["sha"]?.string {
                Text(MediaL.text("pinnedCommit")).font(.caption)
                Text(sha).font(.caption.monospaced()).textSelection(.enabled)
                if draft.listing["truncated"]?.bool == true { Label(MediaL.text("truncated"), systemImage: "exclamationmark.triangle") }
                ForEach(MediaRows.from(draft.folders, key: "path")) { folder in
                    Toggle(isOn: Binding(get: { draft.selected.contains(folder.id) }, set: { selected in
                        if selected { draft.selected.insert(folder.id) } else { draft.selected.remove(folder.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(folder.id.isEmpty ? "/" : folder.id)
                            Text("\(folder.value["files"]?.array?.count ?? 0) " + MediaL.text("images")).font(.caption)
                        }
                    }
                }
                Button(MediaL.text("selectAll")) { draft.selected = Set(draft.folders.compactMap { $0["path"]?.string }) }
                Button(MediaL.text("deselectAll")) { draft.selected = [] }
                Button(MediaL.text(source == nil ? "subscribe" : "saveFolders")) {
                    do {
                        let arguments = try draft.arguments(currentURL: url)
                        action.request(app, "stickers.subscribe", arguments) { _ in action.notice = MediaL.text("subscribed"); draft.invalidate() }
                    } catch { action.failure = error as? NativeFailure }
                }.disabled(draft.selected.isEmpty || action.busy)
                Text(MediaL.text("sourceChangedHelp")).font(.caption).foregroundStyle(.secondary)
            }
            MediaFeedback(action: action)
        }
        .onAppear { initialize() }
        .onChange(of: snapshot) { _ in initialize() }
        .onDisappear { action.cancel() }
    }
    private func initialize() {
        guard !initialized else { return }
        if let source {
            guard let existing = snapshot["subscriptions"]?.array?.first(where: { $0["slug"]?.string == source }),
                  let ref = existing["ref"]?.string else { return }
            // Preserve branch/ref, including slash components; inspect resolves the repository vocabulary.
            url = "https://github.com/\(source)/tree/\(ref)"
        }
        initialized = true
    }
}

private struct MediaPickedFile: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            MediaPickedFile(url: try MediaUploadFiles.copy(received.file))
        }
    }
}

/// No image decode/NSData copy on Main. Files survive sheet dismissal and queue retries.
private enum MediaUploadFiles {
    private static let stager: Result<MediaUploadFileStager, Error> = Result {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NativeMediaUploads", isDirectory: true)
        // Queue is process-local. Remove only the prior process's staging area, before our first copy.
        if fm.fileExists(atPath: base.path) { try fm.removeItem(at: base) }
        return try MediaUploadFileStager(directory: base)
    }
    static func copy(_ source: URL) throws -> URL { try stager.get().copy(source) }
}

private struct MediaUploadCandidate: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
}

private struct MediaUploadPicker: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var action = MediaAction()
    @State private var photos: [PhotosPickerItem] = []
    @State private var candidates: [MediaUploadCandidate] = []
    @State private var files = false
    @State private var keepOriginal = true
    @State private var previewURL: URL?
    @State private var confirm = false
    var body: some View {
        Section(MediaL.text("upload")) {
            PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .current) {
                Label(MediaL.text("photos"), systemImage: "photo.on.rectangle")
            }.disabled(action.busy)
            Button(MediaL.text("imageFiles")) { files = true }.disabled(action.busy)
            ForEach($candidates) { $item in
                HStack {
                    TextField(MediaL.text("name"), text: $item.name)
                    Button(MediaL.text("preview")) { previewURL = item.url }
                    Button(role: .destructive) {
                        candidates.removeAll { $0.id == item.id }
                        try? FileManager.default.removeItem(at: item.url)
                    } label: { Image(systemName: "minus.circle") }.accessibilityLabel(MediaL.text("remove"))
                }
            }
            Toggle(MediaL.text("keepOriginal"), isOn: $keepOriginal)
            Text(MediaL.text("uploadHelp")).font(.caption).foregroundStyle(.secondary)
            Button(MediaL.text("upload")) { confirm = true }.disabled(candidates.isEmpty || action.busy)
            MediaFeedback(action: action)
        }
        .quickLookPreview($previewURL)
        .onChange(of: photos) { selected in
            guard !selected.isEmpty else { return }
            action.run(app) {
                for item in selected {
                    guard let file = try await item.loadTransferable(type: MediaPickedFile.self) else { throw CocoaError(.fileReadCorruptFile) }
                    try Task.checkCancellation()
                    candidates.append(.init(url: file.url, name: "sticker.\(file.url.pathExtension)"))
                }
                photos = []
            }
        }
        .fileImporter(isPresented: $files, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            action.run(app) {
                let urls = try result.get()
                for url in urls.prefix(20) {
                    let copied = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try MediaUploadFiles.copy(url)
                    }.value
                    try Task.checkCancellation()
                    candidates.append(.init(url: copied, name: url.lastPathComponent))
                }
            }
        }
        .confirmationDialog(MediaL.text("uploadConfirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(MediaL.text("upload")) {
                let queued = candidates
                let images = queued.map { JSONValue.object(["source": .string($0.url.absoluteString), "name": .string($0.name)]) }
                action.request(app, "stickers.upload", ["images": .array(images), "keepOriginal": .bool(keepOriginal)]) { _ in
                    candidates.removeAll { item in queued.contains { $0.id == item.id } }
                    action.notice = MediaL.text("queued")
                }
            }
        }
        .onDisappear { action.cancel() }
    }
}
