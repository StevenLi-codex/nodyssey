import SwiftUI
import NodysseyNativeCore

struct LibraryReportsScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    var arguments: [String: JSONValue] = [:]
    @StateObject private var parsed = NativeStore()
    @State private var didParse = false
    @StateObject private var basket = NativeStore()
    @StateObject private var action = LibraryAction()
    @State private var selection = LibraryReportSelection()
    @State private var comparison: JSONValue = .null
    @State private var compared: [JSONValue] = []
    @State private var remove: JSONValue?
    @State private var differencesOnly = false
    @State private var attempt = 0
    private var entries: [JSONValue] { basket.value.array ?? [] }
    var body: some View {
        List {
            LibraryStoreStatus(store: basket) { attempt += 1 }
            LibraryActionStatus(action: action)
            if arguments["code"]?.string != nil {
                Section(libraryL("sourceReport")) {
                    LibraryStoreStatus(store: parsed) { action.run { await parseSource() } }
                    if let entry = parsedEntry {
                        NativeLibraryReportView(report: parsed.value)
                        Button(libraryL("addReport")) {
                            action.run {
                                basket.value = try await app.request("reports.add", ["entry": entry])
                                action.notice = libraryL("reportSaved")
                            }
                        }.disabled(action.busy || entries.contains(entry))
                    } else if didParse && parsed.failure == nil { Text(libraryL("notReport")) }
                }
            }
            Text(libraryL("compareHint")).font(.footnote)
            if entries.isEmpty && !basket.isLoading { NativeEmptyView(libraryL("empty")) }
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading) {
                    HStack {
                        Button { selection.toggle(entry); comparison = .null } label: {
                            Image(systemName: selection.selected.contains(entry) ? "checkmark.circle.fill" : "circle")
                        }.buttonStyle(.borderless).accessibilityLabel(libraryL("select"))
                            .disabled(selection.selected.count >= 3 && !selection.selected.contains(entry))
                        Text(entry["report"]?["title"]?.string ?? libraryL("unknown")).font(.headline)
                        Spacer()
                        Button(role: .destructive) { remove = entry } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel(libraryL("delete"))
                    }
                    if let title = entry["threadTitle"]?.string { Text(title).font(.caption) }
                    if let id = entry["postId"]?.int {
                        Button(libraryL("openThread")) {
                            var args: [String: JSONValue] = ["postId": .integer(id)]
                            if let floor = entry["floor"], floor != .null { args["floor"] = floor }
                            app.open("PostDetail", args)
                        }
                    }
                    if let report = entry["report"] { DisclosureGroup(libraryL("report")) { NativeLibraryReportView(report: report) } }
                }
            }
            Button(libraryL("compare")) {
                action.run {
                    // Validate against the CURRENT basket; never send former list indices.
                    let chosen = try selection.entries(in: entries)
                    let value = try await app.request("reports.compare", ["entries": .array(chosen)])
                    guard chosen.allSatisfy({ entries.contains($0) }) else { comparison = .null; return }
                    compared = chosen; comparison = value
                }
            }.disabled(!(2...3).contains(selection.selected.count) || action.busy)
            if comparison != .null {
                Toggle(libraryL("differencesOnly"), isOn: $differencesOnly)
                Section(libraryL("comparison")) {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                Text(libraryL("field")).frame(width: 140, alignment: .leading)
                                ForEach(Array(compared.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading) {
                                        Text(entry["report"]?["title"]?.string ?? libraryL("unknown")).font(.headline)
                                        if let target = entry["report"]?["target"]?.string { Text(target) }
                                        if let source = entry["threadTitle"]?.string { Text(source).font(.caption) }
                                    }.frame(width: 190, alignment: .leading)
                                }
                            }
                            ForEach(Array((comparison["sections"]?.array ?? []).enumerated()), id: \.offset) { _, section in
                                Text(section["title"]?.string ?? "").font(.headline)
                                ForEach(Array((section["rows"]?.array ?? []).enumerated()), id: \.offset) { _, row in
                                    let cells = row["cells"]?.array ?? []
                                    if !differencesOnly || cells.dropFirst().contains(where: { $0 != cells.first }) {
                                        HStack(alignment: .top) {
                                            Text(row["label"]?.string ?? "").frame(width: 140, alignment: .leading)
                                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                                LibraryReportValues(values: cell.array).frame(width: 190, alignment: .leading)
                                            }
                                        }
                                        Divider()
                                    }
                                }
                            }
                        }.textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(libraryL("reports"))
        .task(id: app.generation) { await parseSource() }
        .task(id: "\(app.generation)-\(attempt)") { selection = LibraryReportSelection(); comparison = .null; await basket.observe(app, "reports.observe") }
        .onChange(of: basket.value) { _ in
            comparison = .null
            for entry in selection.selected where !entries.contains(entry) { selection.toggle(entry) }
            if basket.value == .null { selection = LibraryReportSelection(); compared = [] }
        }
        .confirmationDialog(libraryL("deleteConfirm"), isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
            Button(libraryL("delete"), role: .destructive) {
                guard let entry = remove else { return }; remove = nil
                action.run {
                    basket.value = try await app.request("reports.remove", ["entry": entry])
                    if selection.selected.contains(entry) { selection.toggle(entry) }
                    comparison = .null
                }
            }
        }
        .onDisappear { action.cancel() }
    }
    private var parsedEntry: JSONValue? {
        guard parsed.value.object != nil else { return nil }
        var entry: [String: JSONValue] = ["report": parsed.value]
        for key in ["postId", "threadTitle", "floor"] {
            if let value = arguments[key] { entry[key] = value }
        }
        return .object(entry)
    }
    private func parseSource() async {
        guard let code = arguments["code"]?.string else { return }
        didParse = false
        var input: [String: JSONValue] = ["code": .string(code)]
        if let spans = arguments["spans"] { input["spans"] = spans }
        await parsed.load(app, "reports.parse", input)
        didParse = true
    }
}

/// Structured shared QualityReport renderer. No HTML, inferred identity or JSON debug dump.
/// Available to content owners for shared-parser results; source/ANSI remain with NativeCodeBlock.
struct NativeLibraryReportView: View {
    let report: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report["title"]?.string ?? libraryL("report")).font(.headline)
            ForEach(["target", "generatedAt", "scriptVersion"], id: \.self) { key in
                if let value = report[key]?.string { LibraryField(label: key, value: .string(value)) }
            }
            ForEach(Array((report["sections"]?.array ?? []).enumerated()), id: \.offset) { _, section in
                DisclosureGroup(section["title"]?.string ?? "") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array((section["blocks"]?.array ?? []).enumerated()), id: \.offset) { _, block in
                            reportBlock(block)
                        }
                    }
                }
            }
            ForEach(Array((report["footnotes"]?.array ?? []).enumerated()), id: \.offset) { _, note in
                if let text = note.string { Text(text).font(.footnote) }
            }
        }.textSelection(.enabled)
    }
    @ViewBuilder private func reportBlock(_ block: JSONValue) -> some View {
        switch block["type"]?.string {
        case "field", "badges":
            VStack(alignment: .leading) {
                Text(block["label"]?.string ?? "").font(.subheadline.bold())
                LibraryReportValues(values: block[block["type"]?.string == "field" ? "values" : "items"]?.array)
            }
        case "note": Text(block["text"]?.string ?? "")
        case "table":
            ScrollView(.horizontal) {
                VStack(alignment: .leading) {
                    HStack(alignment: .top) {
                        Text(libraryL("field")).frame(width: 140, alignment: .leading)
                        ForEach(Array((block["columns"]?.array ?? []).enumerated()), id: \.offset) { _, column in
                            Text(column.string ?? "").font(.subheadline.bold()).frame(width: 150, alignment: .leading)
                        }
                    }
                    ForEach(Array((block["rows"]?.array ?? []).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            Text(row["label"]?.string ?? "").frame(width: 140, alignment: .leading)
                            ForEach(Array((row["cells"]?.array ?? []).enumerated()), id: \.offset) { _, cell in
                                LibraryReportValues(values: cell.array ?? [cell]).frame(width: 150, alignment: .leading)
                            }
                        }
                    }
                }
            }
        default: Text(libraryL("unsupportedReportBlock")).foregroundStyle(.secondary)
        }
    }
}

struct LibraryReportValues: View {
    let values: [JSONValue]?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let values {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let tone = value["tone"]?.string ?? "Neutral"
                    Text(value["text"]?.string ?? value.string ?? libraryL("unknown"))
                        .foregroundStyle(color(tone))
                        .accessibilityLabel("\(value["text"]?.string ?? value.string ?? "") · \(libraryL("tone." + tone))")
                }
            } else { Text(libraryL("missing")) }
        }
    }
    private func color(_ tone: String) -> Color {
        switch tone { case "Good": return .green; case "Warn": return .orange; case "Bad": return .red; default: return .primary }
    }
}
