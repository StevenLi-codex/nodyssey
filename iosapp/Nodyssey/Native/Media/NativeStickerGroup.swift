import SwiftUI
import NodysseyNativeCore

struct NativeStickerGroupScreen: View {
    let key: String
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var store = NativeStore()
    @StateObject private var action = MediaAction()
    @State private var interaction = MediaStickerInteraction(mode: .browser)
    @State private var preview: MediaSticker?
    @State private var pendingRemoval: [String] = []
    @State private var confirmRemoval = false
    @State private var renameURL: String?
    @State private var name = ""
    @State private var showRename = false
    @State private var undoURLs: [String] = []
    @State private var retry = 0
    private var group: MediaStickerGroup? { MediaStickerGroup.groups(store.value).first { $0.id == key } }
    private var entries: [MediaSticker] { group?.entries ?? [] }
    private var selected: [MediaSticker] { entries.filter { interaction.selection.contains($0.id) } }
    private var probes: [MediaRows] { MediaRows.from(store.value["linkProbes"]?.array ?? [], key: "url") }
    private var brokenURLs: [String] {
        let mine = Set(entries.compactMap(\.url))
        return probes.filter { mine.contains($0.id) && $0.value["result"]?["type"]?.string == "Broken" }.map(\.id)
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
                if store.isLoading { ProgressView() }
                MediaFeedback(action: action)
                if !store.isLoading && store.failure == nil {
                    if group == nil { Text(MediaL.text("groupMissing")) }
                    else if entries.isEmpty { Text(MediaL.text("noStickers")).foregroundStyle(.secondary) }
                }
                if interaction.selecting {
                    Text(MediaL.text("selectionCount") + ": \(selected.count)").font(.headline)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 144 : 76), spacing: 12)], spacing: 16) {
                    ForEach(entries) { entry in
                        Button { activate(entry) } label: {
                            MediaStickerTile(sticker: entry, selecting: interaction.selecting,
                                             selected: interaction.selection.contains(entry.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(entry.name.isEmpty ? entry.insertion : entry.name)
                        .accessibilityAddTraits(interaction.selection.contains(entry.id) ? .isSelected : [])
                        .contextMenu { entryActions(entry) }
                    }
                }.disabled(action.busy)
                groupActions
            }.padding()
        }
        .navigationTitle(MediaL.text(group?.name ?? key))
        .toolbar {
            Button(MediaL.text(interaction.selecting ? "cancel" : "select")) {
                if interaction.selecting { interaction.endSelection() }
                else { interaction.beginSelection() }
            }.disabled(entries.compactMap(\.url).isEmpty || action.busy)
        }
        .task(id: "\(app.generation)-\(retry)") {
            interaction.endSelection(); preview = nil; undoURLs = []
            await store.observe(app, "stickers.observe")
        }
        .onChange(of: store.value) { value in
            let current = MediaStickerGroup.groups(value).first { $0.id == key }?.entries ?? []
            interaction.reconcile(current)
            if let preview, !current.contains(where: { $0.id == preview.id }) { self.preview = nil }
        }
        .onDisappear { action.cancel() }
        .sheet(item: $preview) { entry in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let url = entry.url {
                            NativeRemoteImage(url: url, aspectFit: true).frame(maxHeight: 280)
                            Text(url).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        probeResult(entry)
                        entryActions(entry)
                    }.padding()
                }
                .navigationTitle(entry.name)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(MediaL.text("close")) { preview = nil } } }
            }
        }
        .confirmationDialog(MediaL.text("removeConfirm"), isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button(MediaL.text("remove"), role: .destructive) {
                action.request(app, "stickers.remove", ["urls": .array(pendingRemoval.map(JSONValue.string))]) { _ in
                    interaction.reconcile(entries.filter { !pendingRemoval.contains($0.id) }); pendingRemoval = []
                }
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

    @ViewBuilder private var groupActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if interaction.selecting {
                Button(MediaL.text(selected.count == entries.compactMap(\.url).count ? "deselectAll" : "selectAll")) {
                    if selected.count == entries.compactMap(\.url).count { interaction.endSelection(); interaction.beginSelection() }
                    else { interaction.selectAll(entries) }
                }
                if key == "mine" {
                    Button(MediaL.text("moveTop")) { action.request(app, "stickers.moveToTop", urls(selected)) }.disabled(selected.isEmpty)
                    Button(MediaL.text("removeSelected"), role: .destructive) { pendingRemoval = selected.compactMap(\.url); confirmRemoval = true }.disabled(selected.isEmpty)
                } else { Button(MediaL.text("collectSelected")) { collect(selected) }.disabled(selected.compactMap(\.url).isEmpty) }
            }
            if let group {
                Toggle(MediaL.text("hidden"), isOn: Binding(get: { group.hidden }, set: { hidden in
                    if let slug = group.slug, let path = group.path {
                        action.request(app, "stickers.folders.hidden", ["slug": .string(slug), "path": .string(path), "hidden": .bool(hidden)])
                    } else { action.request(app, "stickers.groups.hidden", ["key": .string(key), "hidden": .bool(hidden)]) }
                }))
            }
            if key == "mine" {
                Button(MediaL.text("probeMine")) { action.request(app, "stickers.probeMine") }
                Button(MediaL.text("removeBroken"), role: .destructive) { pendingRemoval = brokenURLs; confirmRemoval = true }.disabled(brokenURLs.isEmpty)
            }
            let exported = interaction.selecting ? selected : entries
            if !exported.compactMap(\.url).isEmpty {
                ShareLink(item: exported.compactMap(\.url).joined(separator: "\n")) { Text(MediaL.text("exportLinks")) }
            }
            if !undoURLs.isEmpty {
                Button(MediaL.text("undoCollection")) {
                    let undo = undoURLs
                    action.request(app, "stickers.remove", ["urls": .array(undo.map(JSONValue.string))]) { _ in undoURLs = [] }
                }
            }
        }.disabled(action.busy)
    }

    @ViewBuilder private func entryActions(_ entry: MediaSticker) -> some View {
        if let url = entry.url {
            Button(MediaL.text("view")) {
                preview = nil
                let urls = entries.compactMap(\.url)
                app.open("ImageViewer", ["urls": .array(urls.map(JSONValue.string)), "index": .integer(Int64(urls.firstIndex(of: url) ?? 0))])
            }
            ShareLink(item: url) { Text(MediaL.text("copyShare")) }
            Button(MediaL.text("select")) { preview = nil; interaction.beginSelection(); _ = interaction.activate(entry) }
            Button(MediaL.text("probe")) { preview = nil; action.request(app, "stickers.probe", ["url": .string(url)]) }
            if key == "mine" {
                Button(MediaL.text("rename")) { preview = nil; renameURL = url; name = entry.name; showRename = true }
                Button(MediaL.text("moveTop")) { preview = nil; action.request(app, "stickers.moveToTop", ["urls": .array([.string(url)])]) }
                Button(MediaL.text("moveEarlier")) { move(entry, by: -1) }.disabled(entries.first?.id == entry.id)
                Button(MediaL.text("moveLater")) { move(entry, by: 1) }.disabled(entries.last?.id == entry.id)
                Button(MediaL.text("remove"), role: .destructive) { preview = nil; pendingRemoval = [url]; confirmRemoval = true }
            } else { Button(MediaL.text("collect")) { preview = nil; collect([entry]) } }
        }
    }
    @ViewBuilder private func probeResult(_ entry: MediaSticker) -> some View {
        if let result = probes.first(where: { $0.id == entry.url })?.value["result"] {
            HStack {
                Text(MediaL.text(result["type"]?.string ?? "unreachable"))
                if let size = result["sizeBytes"]?.int { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let code = result["code"]?.int { Text("HTTP \(code)") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private func activate(_ entry: MediaSticker) {
        if case .preview(let sticker) = interaction.activate(entry) { preview = sticker }
    }
    private func move(_ entry: MediaSticker, by delta: Int) {
        var ordered = entries.compactMap(\.url)
        guard let index = ordered.firstIndex(of: entry.id), ordered.indices.contains(index + delta) else { return }
        ordered.swapAt(index, index + delta); preview = nil
        action.request(app, "stickers.reorder", ["urls": .array(ordered.map(JSONValue.string))])
    }
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

/// Explicit editor picker: emits canonical shortcode/Unicode/Markdown, not preview URLs.
struct NativeStickerPicker: View {
    let onSelect: (String) -> Void
    var compactKeyboard = false
    var onManage: (() -> Void)? = nil
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var store = NativeStore()
    @State private var interaction = MediaStickerInteraction(mode: .picker)
    @State private var retry = 0
    @State private var key: String?
    private func manage() { if let onManage { onManage() } else { app.open("StickerManage") } }
    private var groups: [MediaStickerGroup] { MediaStickerGroup.groups(store.value).filter { !$0.hidden } }
    private var entries: [MediaSticker] { groups.first(where: { $0.id == (key ?? groups.first?.id) })?.entries ?? [] }
    var body: some View {
        VStack {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if store.isLoading { ProgressView() }
            HStack {
                Picker(MediaL.text("groups"), selection: Binding(get: { key ?? groups.first?.id ?? "" }, set: { key = $0 })) {
                    ForEach(groups) { group in Text(MediaL.text(group.name)).tag(group.id) }
                }.pickerStyle(.menu)
                if compactKeyboard {
                    Spacer(minLength: 0)
                    Button(MediaL.text("manage"), action: manage).frame(minHeight: 44)
                }
            }.padding(.horizontal, compactKeyboard ? 12 : 0)
            ScrollView {
                if entries.isEmpty && !store.isLoading && store.failure == nil { Text(MediaL.text("noStickers")) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 144 : (compactKeyboard ? 80 : 76)))]) {
                    ForEach(entries) { sticker in
                        Button {
                            if case .insert(let text) = interaction.activate(sticker) { onSelect(text) }
                        } label: { MediaStickerTile(sticker: sticker) }
                        .buttonStyle(.plain).accessibilityLabel(sticker.name.isEmpty ? sticker.insertion : sticker.name)
                    }
                }.padding()
            }
            if !compactKeyboard { Button(MediaL.text("manage"), action: manage) }
        }
        .frame(maxHeight: compactKeyboard ? .infinity : nil)
        .task(id: "\(app.generation)-\(retry)") { await store.observe(app, "stickers.observe") }
        .onChange(of: store.value) { _ in if !groups.contains(where: { $0.id == key }) { key = groups.first?.id } }
    }
}

/// The parent button owns activation so a thumbnail never inserts and opens a viewer together.
private struct MediaStickerTile: View {
    let sticker: MediaSticker
    var selecting = false
    var selected = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Color.secondary.opacity(0.08).aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url = sticker.url {
                            NativeRemoteImage(url: url, aspectFit: true).padding(6).allowsHitTesting(false)
                        } else { Text(sticker.insertion).font(.largeTitle) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if selecting && sticker.url != nil {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary).padding(4)
                }
            }
            Text(sticker.name).font(.caption).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                .frame(maxWidth: .infinity)
        }.contentShape(Rectangle()).accessibilityElement(children: .ignore)
    }
}
