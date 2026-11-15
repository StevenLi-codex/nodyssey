import SwiftUI
import NodysseyNativeCore

struct LibraryBookmarksScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var snapshot = NativeStore()
    @StateObject private var offline = NativeStore()
    @StateObject private var capabilities = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var selection = LibrarySelection()
    @State private var query = ""
    @State private var filter = "all"
    @State private var sort = "site"
    @State private var selecting = false
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var truncated = false
    @State private var estimate: Int64?
    @State private var failures: [Int64: NativeFailure] = [:]
    @State private var watchAttempt = 0
    @State private var managingOffline = false

    private var rows: [JSONValue] { snapshot.value.array ?? [] }
    private var visible: [JSONValue] { LibraryRows.visible(rows, offline: offline.value, query: query, filter: filter, sort: sort) }
    private var available: Bool { offline.value["isAvailable"]?.bool == true }
    private var selectedIDs: [Int64] { selection.selected.sorted() }

    var body: some View {
        List {
            LibraryStoreStatus(store: snapshot) { watchAttempt += 1 }
            LibraryActionStatus(action: action)
            if truncated { Text(libraryL("truncated")).font(.footnote) }
            Section {
                Picker(libraryL("filter"), selection: $filter) {
                    Text("\(libraryL("all")) · \(rows.count)").tag("all")
                    if available {
                        Text("\(libraryL("downloaded")) · \(filterCount("downloaded"))").tag("downloaded")
                        Text("\(libraryL("newReplies")) · \(filterCount("new"))").tag("new")
                    }
                }
                if selecting {
                    Text("\(libraryL("selected")): \(selection.selected.count)")
                    Button(libraryL("selectVisible")) { selection.selectVisible(visible.compactMap { $0["postId"]?.int }) }
                    Button(libraryL("delete"), role: .destructive) { confirmDelete = true }.disabled(selectedIDs.isEmpty || action.busy)
                    if available {
                        Button(libraryL("estimate")) {
                            let ids = selectedIDs
                            action.run {
                                let result = try await app.request("offline.estimate", ["postIds": .array(ids.map(JSONValue.integer))])
                                estimate = result["bytes"]?.int
                            }
                        }.disabled(selectedIDs.isEmpty || action.busy)
                        Text(estimate.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? libraryL("estimateUnknown"))
                        Button(libraryL("downloadSelected")) { download(selectedIDs) }.disabled(selectedIDs.isEmpty || action.busy)
                    }
                }
                if !selection.undoIDs.isEmpty {
                    Button(libraryL("undo")) { changeCollection(selection.undoIDs.sorted(), collected: true) }.disabled(action.busy)
                }
            }
            if !failures.isEmpty {
                Section(libraryL("partialFailures")) {
                    ForEach(failures.keys.sorted(), id: \.self) { id in
                        VStack(alignment: .leading) {
                            Text("#\(id)")
                            if let failure = failures[id] { NativeFailureView(failure: failure) }
                        }
                    }
                }
            }
            if visible.isEmpty && !snapshot.isLoading && snapshot.failure == nil {
                NativeEmptyView(libraryL(!query.isEmpty ? "emptySearch" : filter != "all" ? "emptyFilter" : "empty"))
            }
            ForEach(visible.compactMap(LibraryIdentifiedRow.init)) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if selecting {
                            Button {
                                if selection.selected.contains(item.id) { selection.selected.remove(item.id) }
                                else { selection.selected.insert(item.id) }
                            } label: { Image(systemName: selection.selected.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                            .buttonStyle(.borderless).accessibilityLabel(libraryL("select"))
                        }
                        LibraryPostRow(row: item.value, select: selecting ? { toggle(item.id) } : nil)
                    }
                    if let state = LibraryRows.state(item.id, offline: offline.value) {
                        offlineState(state, id: item.id)
                    }
                    if let failure = failures[item.id] { NativeFailureView(failure: failure) }
                }
                .onLongPressGesture { selecting = true; toggle(item.id) }
                .swipeActions {
                    Button(libraryL("delete"), role: .destructive) {
                        selection.selected = [item.id]; confirmDelete = true
                    }
                    if available { Button(libraryL("download")) { download([item.id]) }.tint(.blue) }
                }
            }
        }
        .navigationTitle(libraryL("bookmarks"))
        .searchable(text: $query, prompt: libraryL("search"))
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItemGroup {
                Menu(libraryL("sort")) {
                Picker(libraryL("sort"), selection: $sort) {
                    Text(libraryL("siteOrder")).tag("site")
                    Text(libraryL("replies")).tag("replies")
                    Text(libraryL("pendingFirst")).tag("pending")
                }
                }
                if !selecting {
                    Button(libraryL("select")) { selecting = true }
                } else {
                    Button(libraryL("done")) { selecting = false; selection.selected.removeAll() }
                }
                if available {
                    Button(libraryL("offlineManage")) { managingOffline = true }
                }
                Button(libraryL("refresh")) { action.run { await refresh() } }.disabled(action.busy)
            }
        }
        .confirmationDialog(libraryL("deleteConfirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(libraryL("delete"), role: .destructive) { changeCollection(selectedIDs, collected: false) }
        }
        .task(id: "\(app.generation)-\(watchAttempt)") {
            selection = LibrarySelection(); failures = [:]; truncated = false
            // Explicit disk snapshot first; observing the same SSOT then triggers remote refresh.
            await snapshot.load(app, "bookmarks.snapshot")
            do {
                var first = true
                for try await value in app.transport.observe("bookmarks.snapshot", [:]) {
                    try Task.checkCancellation()
                    snapshot.value = value
                    if value == .null { selection = LibrarySelection(); failures = [:] }
                    if first { first = false; action.run { await refresh() } }
                }
            } catch is CancellationError { }
            catch let error as NativeFailure { snapshot.failure = error }
            catch { snapshot.failure = NativeFailure(code: "INTERNAL", message: "") }
        }
        .task(id: app.generation) { await offline.observe(app, "offline.observe") }
        .task(id: app.generation) { await capabilities.load(app, "settings.capabilities") }
        .onChange(of: selection.selected) { _ in estimate = nil }
        .onChange(of: available) { value in if !value { filter = "all" } }
        .onDisappear { action.cancel() }
        .sheet(isPresented: $managingOffline) {
            NavigationStack {
                List { LibraryActionStatus(action: action); offlineManagement }
                    .navigationTitle(libraryL("offline"))
                    .toolbar { Button(libraryL("done")) { managingOffline = false }.disabled(action.busy) }
        .confirmationDialog(libraryL("clearOfflineConfirm"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(libraryL("clear"), role: .destructive) {
                action.run { offline.value = try await app.request("offline.clear") }
            }
        }
            }.interactiveDismissDisabled(action.busy)
        }
    }

    private func toggle(_ id: Int64) {
        if selection.selected.contains(id) { selection.selected.remove(id) }
        else { selection.selected.insert(id) }
    }
    private func filterCount(_ value: String) -> Int {
        LibraryRows.visible(rows, offline: offline.value, query: "", filter: value, sort: "site").count
    }

    @ViewBuilder private func offlineState(_ state: JSONValue, id: Int64) -> some View {
        let name = state["state"]?.string ?? "NotDownloaded"
        Text(libraryL("offline." + name)).font(.caption)
        if name == "Downloading" {
            if case .number(let progress) = state["progress"] { ProgressView(value: progress) }
            else if let progress = state["progress"]?.int { ProgressView(value: Double(progress)) }
            else { ProgressView() }
            Button(libraryL("cancel")) { action.run { offline.value = try await app.request("offline.cancel", ["postId": .integer(id)]) } }
        }
        if let bytes = state["bytes"]?.int { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption) }
        if let behind = state["behindReplies"]?.int { Text("\(libraryL("newReplies")): \(behind)").font(.caption) }
        if let reason = state["reason"]?.string { Text(libraryL("offline." + reason)).font(.caption).foregroundStyle(.secondary) }
    }

    private var offlineManagement: some View {
        Section(libraryL("offline")) {
            LibraryStoreStatus(store: offline)
            if available {
                ForEach(["posts", "textBytes", "imageBytes", "freeBytes", "totalBytes"], id: \.self) { key in
                    LibraryField(label: key, value: offline.value["usage"]?[key])
                }
                ForEach(["wifiOnly", "autoSyncReplies"], id: \.self) { key in
                    Toggle(libraryL(key), isOn: Binding(get: { offline.value["settings"]?[key]?.bool == true }, set: { value in
                        action.run { offline.value = try await app.request("offline.settings", [key: .bool(value)]) }
                    })).disabled(action.busy)
                }
                if capabilities.value["offlineImageReading"]?.bool == true {
                    Toggle(libraryL("includeImages"), isOn: Binding(get: { offline.value["settings"]?["includeImages"]?.bool == true }, set: { value in
                        action.run { offline.value = try await app.request("offline.settings", ["includeImages": .bool(value)]) }
                    })).disabled(action.busy)
                } else { Text(libraryL("offlineImagesUnavailable")).font(.footnote) }
                Picker(libraryL("retentionDays"), selection: Binding(get: { offline.value["settings"]?["retentionDays"]?.int ?? 0 }, set: { value in
                    action.run { offline.value = try await app.request("offline.settings", ["retentionDays": .integer(value)]) }
                })) {
                    ForEach([Int64(7), 30, 90, 0], id: \.self) { day in Text(day == 0 ? libraryL("forever") : String(day)).tag(day) }
                }.disabled(action.busy)
                Button(libraryL("downloadPending")) {
                    download(rows.compactMap { row in
                        guard let id = row["postId"]?.int else { return nil }
                        let state = LibraryRows.state(id, offline: offline.value)?["state"]?.string ?? "NotDownloaded"
                        return ["NotDownloaded", "Failed"].contains(state) ? id : nil
                    })
                }.disabled(action.busy)
                Button(libraryL("clearOffline"), role: .destructive) { confirmClear = true }.disabled(action.busy)
            } else { Text(libraryL("offlineUnavailable")) }
        }
    }
    private func download(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        action.run { offline.value = try await app.request("offline.download", ["postIds": .array(ids.map(JSONValue.integer))]) }
    }
    private func refresh() async {
        do {
            let result = try await app.request("bookmarks.refresh")
            truncated = result["truncated"]?.bool == true
            snapshot.value = result["items"] ?? .null
            snapshot.failure = nil
        } catch is CancellationError { }
        catch let error as NativeFailure { snapshot.failure = error }
        catch { snapshot.failure = NativeFailure(code: "INTERNAL", message: "") }
    }
    private func changeCollection(_ ids: [Int64], collected: Bool) {
        action.run {
            _ = try await LibraryOperations.collect(ids, collected: collected, progress: { result in
                failures = result.failures
                if collected { selection.undoIDs.subtract(result.succeeded) }
                else { selection.completeRemoval(succeeded: result.succeeded, failed: Set(result.failures.keys)) }
            }, request: app.request)
            // Read the authoritative persisted collection even when some mutations failed.
            snapshot.value = try await app.request("bookmarks.snapshot")
        }
    }
}

struct LibraryIdentifiedRow: Identifiable {
    let id: Int64
    let value: JSONValue
    init?(_ value: JSONValue) {
        guard let id = value["postId"]?.int, id > 0 else { return nil }
        self.id = id; self.value = value
    }
}

struct LibraryHistoryScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var settings = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var undo = LibraryHistoryUndo()
    @State private var removing: Int64?
    @State private var clear = false
    @State private var attempt = 0
    @State private var managing = false
    private var groups: [(Int, [JSONValue])] {
        let grouped = Dictionary(grouping: store.value.array ?? []) { LibraryRows.historyBucket($0) }
        return grouped.keys.sorted().map { ($0, (grouped[$0] ?? []).sorted { ($0["lastReadAtMillis"]?.int ?? 0) > ($1["lastReadAtMillis"]?.int ?? 0) }) }
    }
    var body: some View {
        List {
            LibraryStoreStatus(store: store) { attempt += 1 }
            LibraryActionStatus(action: action)
            if undo.latest != nil {
                Button(libraryL("undo")) {
                    action.run {
                        store.value = try await undo.restore(request: app.request)
                    }
                }.disabled(action.busy)
            }
            if store.value.array?.isEmpty == true { NativeEmptyView(libraryL("empty")) }
            ForEach(groups, id: \.0) { day, entries in
                Section(libraryL(["today", "yesterday", "week", "earlier"][day])) {
                    ForEach(entries.compactMap(LibraryIdentifiedRow.init)) { item in
                        LibraryPostRow(row: item.value, showsReadTime: true).swipeActions {
                            Button(libraryL("delete"), role: .destructive) { removing = item.id }
                        }
                    }
                }
            }
        }
        .navigationTitle(libraryL("history"))
        .toolbar {
            Menu(libraryL("manage")) {
                Button(libraryL("retention")) { managing = true }
                Button(libraryL("clearHistory"), role: .destructive) { clear = true }.disabled(action.busy)
            }
        }
        .sheet(isPresented: $managing) {
            NavigationStack { Form {
            Section(libraryL("retention")) {
                LibraryStoreStatus(store: settings)
                Picker(libraryL("historyLimit"), selection: Binding(get: { settings.value["readHistoryLimit"]?.int ?? 300 }, set: { value in
                    action.run { settings.value = try await app.request("settings.set", ["key": .string("readHistoryLimit"), "value": .integer(value)]) }
                })) {
                    ForEach(historyLimits, id: \.self) { value in Text(value == Int64(Int32.max) ? libraryL("forever") : String(value)).tag(value) }
                }.disabled(action.busy || settings.value == .null)
            }
            LibraryActionStatus(action: action)
            }.navigationTitle(libraryL("retention"))
                .toolbar { Button(libraryL("done")) { managing = false }.disabled(action.busy) }
            }.interactiveDismissDisabled(action.busy)
        }
        .task(id: "\(app.generation)-\(attempt)") { undo.reset(); await store.observe(app, "history.list") }
        .task(id: app.generation) { await settings.load(app, "settings.get") }
        .refreshable { await libraryRead(store, app, "history.list") }
        .confirmationDialog(libraryL("deleteConfirm"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(libraryL("delete"), role: .destructive) {
                guard let id = removing else { return }; removing = nil
                action.run {
                    let result = try await app.request("history.remove", ["postId": .integer(id), "confirmed": .bool(true)])
                    try undo.record(result)
                    store.value = try await app.request("history.list")
                }
            }
        }
        .confirmationDialog(libraryL("clearHistoryConfirm"), isPresented: $clear, titleVisibility: .visible) {
            Button(libraryL("clear"), role: .destructive) {
                action.run {
                    _ = try await app.request("history.clear", ["confirmed": .bool(true)])
                    undo.reset(); store.value = try await app.request("history.list")
                }
            }
        }
        .onChange(of: store.value) { value in if value == .null { undo.reset() } }
        .onDisappear { action.cancel() }
    }
    private var historyLimits: [Int64] { Array(Set([Int64(100), 300, 1000, Int64(Int32.max)] + [settings.value["readHistoryLimit"]?.int].compactMap { $0 })).sorted() }
}

struct LibraryTrackedScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var removing: Int64?
    @State private var attempt = 0
    var body: some View {
        List {
            LibraryStoreStatus(store: store) { attempt += 1 }
            LibraryActionStatus(action: action)
            if store.value.array?.isEmpty == true { NativeEmptyView(libraryL("empty")) }
            ForEach((store.value.array ?? []).compactMap(LibraryIdentifiedRow.init)) { item in
                LibraryPostRow(row: item.value, countKey: "lastKnownCount").swipeActions {
                    Button(libraryL("untrack"), role: .destructive) { removing = item.id }
                }
            }
        }
        .navigationTitle(libraryL("tracked"))
        .task(id: "\(app.generation)-\(attempt)") { await store.observe(app, "tracked.observe") }
        .confirmationDialog(libraryL("untrack"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(libraryL("untrack"), role: .destructive) {
                guard let id = removing else { return }; removing = nil
                action.run { store.value = try await app.request("tracked.remove", ["postId": .integer(id)]) }
            }
        }
        .onDisappear { action.cancel() }
    }
}
