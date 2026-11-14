import SwiftUI
import NodysseyNativeCore

struct NativeStickerGroupScreen: View {
    let key: String
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var selection: Set<String> = []
    @State private var pendingRemoval: [String] = []
    @State private var confirmRemoval = false
    @State private var renameURL: String?
    @State private var name = ""
    @State private var showRename = false
    @State private var undoURLs: [String] = []
    @State private var retry = 0
    private var group: MediaStickerGroup? { MediaStickerGroup.groups(store.value).first { $0.id == key } }
    private var entries: [MediaSticker] { group?.entries ?? [] }
    private var selected: [MediaSticker] { entries.filter { selection.contains($0.id) } }
    private var probes: [MediaRows] { MediaRows.from(store.value["linkProbes"]?.array ?? [], key: "url") }
    private var brokenURLs: [String] {
        let mine = Set(entries.compactMap(\.url))
        return probes.filter { mine.contains($0.id) && $0.value["result"]?["type"]?.string == "Broken" }.map(\.id)
    }
    var body: some View {
        List {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if store.isLoading { ProgressView() }
            MediaFeedback(action: action)
            if group == nil && !store.isLoading { Text(MediaL.text("groupMissing")) }
            Section {
                ForEach(entries) { entry in
                    HStack {
                        Button { toggle(entry.id) } label: {
                            HStack {
                                Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                MediaStickerCell(sticker: entry)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            if let url = entry.url {
                                Button(MediaL.text("view")) { app.open("ImageViewer", ["urls": .array(entries.compactMap(\.url).map(JSONValue.string)), "index": .integer(Int64(entries.compactMap(\.url).firstIndex(of: url) ?? 0))]) }
                                ShareLink(item: url) { Text(MediaL.text("copyShare")) }
                                Button(MediaL.text("probe")) { action.request(app, "stickers.probe", ["url": .string(url)]) }
                                if key == "mine" {
                                    Button(MediaL.text("rename")) { renameURL = url; name = entry.name; showRename = true }
                                    Button(MediaL.text("moveTop")) { action.request(app, "stickers.moveToTop", ["urls": .array([.string(url)])]) }
                                    Button(MediaL.text("remove"), role: .destructive) { pendingRemoval = [url]; confirmRemoval = true }
                                } else { Button(MediaL.text("collect")) { collect([entry]) } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    if let result = probes.first(where: { $0.id == entry.url })?.value["result"] {
                        HStack {
                            Text(MediaL.text(result["type"]?.string ?? "unreachable"))
                            if let size = result["sizeBytes"]?.int { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                            if let code = result["code"]?.int { Text("HTTP \(code)") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }.onMove { offsets, destination in
                    guard key == "mine" else { return }
                    var urls = entries.compactMap(\.url); urls.move(fromOffsets: offsets, toOffset: destination)
                    action.request(app, "stickers.reorder", ["urls": .array(urls.map(JSONValue.string))])
                }.moveDisabled(key != "mine")
            }.disabled(action.busy)
            Section {
                Button(MediaL.text(selection.count == entries.count ? "deselectAll" : "selectAll")) {
                    selection = selection.count == entries.count ? [] : Set(entries.map(\.id))
                }
                if key == "mine" {
                    Button(MediaL.text("moveTop")) { action.request(app, "stickers.moveToTop", urls(selected)) }.disabled(selected.isEmpty)
                    Button(MediaL.text("removeSelected"), role: .destructive) { pendingRemoval = selected.compactMap(\.url); confirmRemoval = true }.disabled(selected.isEmpty)
                    Button(MediaL.text("probeMine")) { action.request(app, "stickers.probeMine") }
                    Button(MediaL.text("removeBroken"), role: .destructive) { pendingRemoval = brokenURLs; confirmRemoval = true }.disabled(brokenURLs.isEmpty)
                } else { Button(MediaL.text("collectSelected")) { collect(selected) }.disabled(selected.compactMap(\.url).isEmpty) }
                if !selected.isEmpty { ShareLink(item: selected.compactMap(\.url).joined(separator: "\n")) { Text(MediaL.text("exportLinks")) } }
                if !undoURLs.isEmpty {
                    Button(MediaL.text("undoCollection")) {
                        let undo = undoURLs
                        action.request(app, "stickers.remove", ["urls": .array(undo.map(JSONValue.string))]) { _ in undoURLs = [] }
                    }
                }
            }.disabled(action.busy)
        }
        .navigationTitle(MediaL.text(group?.name ?? key))
        .toolbar { if key == "mine" { EditButton() } }
        .task(id: "\(app.generation)-\(retry)") { selection = []; undoURLs = []; await store.observe(app, "stickers.observe") }
        .onChange(of: store.value) { value in
            selection.formIntersection(Set(MediaStickerGroup.groups(value).first { $0.id == key }?.entries.map(\.id) ?? []))
        }
        .onDisappear { action.cancel() }
        .confirmationDialog(MediaL.text("removeConfirm"), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(MediaL.text("remove"), role: .destructive) {
                action.request(app, "stickers.remove", ["urls": .array(pendingRemoval.map(JSONValue.string))]) { _ in selection.subtract(pendingRemoval); pendingRemoval = [] }
            }
        }
        .alert(MediaL.text("rename"), isPresented: $showRename) {
            TextField(MediaL.text("name"), text: $name)
            Button(MediaL.text("save")) {
                if let renameURL { action.request(app, "stickers.rename", ["url": .string(renameURL), "name": .string(name)]) }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(MediaL.text("cancel"), role: .cancel) {}
        }
    }
    private func toggle(_ id: String) { if !selection.insert(id).inserted { selection.remove(id) } }
    private func urls(_ entries: [MediaSticker]) -> [String: JSONValue] { ["urls": .array(entries.compactMap(\.url).map(JSONValue.string))] }
    private func collect(_ entries: [MediaSticker]) {
        let stickers = entries.compactMap { entry -> JSONValue? in
            guard let url = entry.url else { return nil }
            return .object(["url": .string(url), "name": .string(entry.name)])
        }
        action.request(app, "stickers.add", ["stickers": .array(stickers)]) { result in
            // Undo only newly inserted URLs, never a pre-existing collection entry.
            undoURLs = result["addedUrls"]?.array?.compactMap(\.string) ?? []
        }
    }
}

/// Optional editor integration: emits the canonical shortcode/Unicode/Markdown, never preview URLs for site stickers.
struct NativeStickerPicker: View {
    let onSelect: (String) -> Void
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @State private var retry = 0
    @State private var key: String?
    private var groups: [MediaStickerGroup] { MediaStickerGroup.groups(store.value).filter { !$0.hidden } }
    var body: some View {
        VStack {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            Picker(MediaL.text("groups"), selection: Binding(get: { key ?? groups.first?.id ?? "" }, set: { key = $0 })) {
                ForEach(groups) { group in Text(MediaL.text(group.name)).tag(group.id) }
            }.pickerStyle(.menu)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))]) {
                    ForEach(groups.first(where: { $0.id == (key ?? groups.first?.id) })?.entries ?? []) { sticker in
                        Button { onSelect(sticker.insertion) } label: {
                            VStack {
                                if let url = sticker.url { NativeRemoteImage(url: url, aspectFit: true).frame(height: 48).allowsHitTesting(false) }
                                else { Text(sticker.insertion).font(.largeTitle) }
                                Text(sticker.name).font(.caption).lineLimit(1)
                            }
                        }.accessibilityLabel(sticker.name)
                    }
                }.padding()
            }
            Button(MediaL.text("manage")) { app.open("StickerManage") }
        }
        .task(id: "\(app.generation)-\(retry)") { await store.observe(app, "stickers.observe") }
        .onChange(of: store.value) { _ in if !groups.contains(where: { $0.id == key }) { key = groups.first?.id } }
    }
}
