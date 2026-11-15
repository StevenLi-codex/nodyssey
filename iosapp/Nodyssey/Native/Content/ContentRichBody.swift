import SwiftUI
import NodysseyNativeCore

struct ContentRichBody: View {
    @EnvironmentObject private var app: NativeAppModel
    let value: JSONValue
    let postID: Int64
    var threadTitle: String? = nil
    var floor: String? = nil
    var role: NativeRichTextRole = .body
    var jump: (String) -> Void
    @State private var poll: ContentRichPoll?
    @State private var report: ContentRichReport?
    private var decoded: Result<[NativeRichNode], Error> { Result { try JSONDecoder().decode([NativeRichNode].self, from: value.nativeEncoded()) } }
    var body: some View {
        Group {
            switch decoded {
            case .failure:
                NativeFailureView(failure: .init(code: "INVALID_DATA", message: "Unable to decode rich content"))
            case .success(let nodes):
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(nodes.indices, id: \.self) { index in
                        if case .vote(let voteID) = nodes[index] {
                            ContentPollView(voteID: voteID).id(voteID)
                        } else {
                            NativeRichTextView(nodes: [nodes[index]], actions: actions)
                        }
                    }
                }
            }
        }
        .modifier(NativeRichTextPresentation(role: role))
        .environment(\.nativeRichTextRole, role)
        .sheet(item: $poll) { poll in NavigationStack { ScrollView { ContentPollView(voteID: poll.id).padding() }.toolbar { Button(String(localized: "content.close", table: "Content")) { self.poll = nil } } } }
        .sheet(item: $report) { report in NavigationStack { ContentReportView(code: report.code, postID: postID, sourceOverride: report.sourceOverride, threadTitle: threadTitle, floor: floor) } }
        .onChange(of: app.generation) { _ in poll = nil; report = nil }
    }
    private var actions: NativeRichTextActions {
        NativeRichTextActions(
            onImage: ContentImageGallery.onImage(value: value, open: { app.open($0, $1) }),
            onVote: { poll = ContentRichPoll(id: $0) },
            onStardust: { receive in
                app.open("Stardust", ["memberId": .integer(receive.memberId), "refId": .integer(receive.refId), "amount": .integer(Int64(receive.amount)), "description": .string(receive.description), "onetime": .bool(receive.onetime)])
            },
            onLink: { url in
                if url.hasPrefix("#"), ContentReadingTarget.floorNumber(url) != nil { jump(url) }
                else { app.openLink(url) }
            },
            onQuoteReference: { _, floor, url in
                if url.hasPrefix("#") || url.hasPrefix("/post-\(postID)-") { jump(floor) }
                else {
                    let base = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
                    app.openLink(base + (floor.hasPrefix("#") ? floor : "#" + floor))
                }
            },
            onCode: { code, action in
                // Explicit source/adapted actions override only this report. Compare follows settings.
                report = ContentRichReport(code: code, sourceOverride: action == .source ? true : action == .adaptedReport ? false : nil)
            },
            codeContent: { code, inheritedActions in
                // A content-derived ID must not vary with JSON dictionary key order.
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                return AnyView(ContentReportView(
                    code: code, postID: postID, threadTitle: threadTitle, floor: floor,
                    inline: true, actions: inheritedActions
                ).id(try? encoder.encode(code)))
            }
        )
    }
}

private struct ContentRichPoll: Identifiable { let id: Int64 }
private struct ContentRichReport: Identifiable { let id = UUID(); let code: NativeCode; let sourceOverride: Bool? }


struct ContentReportView: View {
    @Environment(\.nativeRichTextRole) private var role
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let code: NativeCode
    let postID: Int64
    let threadTitle: String?
    let floor: String?
    @State private var mode: ContentReportMode
    private var source: Bool { mode.source(settings: app.settings) }
    @StateObject private var store = NativeStore()
    @StateObject private var command = ContentCommand()
    @State private var retry = 0
    let inline: Bool
    var actions: NativeRichTextActions
    init(code: NativeCode, postID: Int64, sourceOverride: Bool? = nil, threadTitle: String? = nil, floor: String? = nil, inline: Bool = false, actions: NativeRichTextActions = .init()) {
        self.code = code; self.postID = postID; self.threadTitle = threadTitle; self.floor = floor
        self.inline = inline; self.actions = actions
        _mode = State(initialValue: ContentReportMode(sourceOverride: sourceOverride))
    }
    var body: some View {
        Group {
            if inline { VStack(alignment: .leading, spacing: 12) { reportContent } }
            else {
                List { reportContent }
                    .navigationTitle(Text(String(localized: "content.report", table: "Content")))
                    .toolbar { Button(String(localized: "content.close", table: "Content")) { dismiss() } }
            }
        }
        .task(id: "\(app.generation)|\(retry)") {
            do {
                let spans = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(code.spans))
                await store.load(app, "reports.parse", ["code": .string(code.code), "spans": spans])
            } catch { command.failure = .init(code: "INVALID_DATA", message: "Unable to encode report spans") }
        }
        .onDisappear { command.cancel() }
    }
    @ViewBuilder private var reportContent: some View {
        if inline && store.value == .null {
            // Ordinary code is not a report. Keep its real source visible while parsing,
            // and do not offer an adapted/source picker unless Kotlin recognized a report.
            NativeCodeBlock(code: code, actions: actions)
            ContentStoreStatus(store: store) { retry += 1 }
        } else {
            reportDetails
        }
    }
    @ViewBuilder private var reportDetails: some View {
        Picker(String(localized: "content.reportFormat", table: "Content"), selection: Binding(get: { source }, set: { mode.sourceOverride = $0 })) {
            Text(String(localized: "content.adapted", table: "Content")).tag(false)
            Text(String(localized: "content.source", table: "Content")).tag(true)
        }.pickerStyle(.segmented)
        ContentCommandStatus(command: command)
        if source { NativeCodeBlock(code: code, actions: actions) }
        else {
            ContentStoreStatus(store: store) { retry += 1 }
            if store.value != .null {
                Text(store.value.nativeString("title") ?? "").font(role == .signature ? .footnote.bold() : .title2)
                ForEach(["target", "generatedAt", "scriptVersion"], id: \.self) { key in
                    if let text = store.value.nativeString(key) { Text(text).font(role == .signature ? .footnote : .subheadline) }
                }
                let sections = store.value.nativeArray("sections")
                ForEach(sections.indices, id: \.self) { index in
                    Section {
                        let blocks = sections[index].nativeArray("blocks")
                        ForEach(blocks.indices, id: \.self) { block in reportBlock(blocks[block]) }
                    } header: { Text(sections[index].nativeString("title") ?? "") }
                }
                ForEach(Array(store.value.nativeArray("footnotes").enumerated()), id: \.offset) { _, note in Text(note.string ?? "").font(.footnote).textSelection(.enabled) }
                Button(String(localized: "content.compare", table: "Content")) {
                    command.run(app) {
                        _ = try await app.request("reports.add", ["entry": .object(["report": store.value, "postId": .integer(postID), "threadTitle": threadTitle.map(JSONValue.string) ?? .null, "floor": floor.map(JSONValue.string) ?? .null])])
                        _ = try await app.request("reports.get")
                        try Task.checkCancellation()
                        if !inline { dismiss() }; app.open("ReportCompare")
                    }
                }.disabled(command.busy)
            } else if !store.isLoading && store.failure == nil {
                Text(String(localized: "content.notReport", table: "Content"))
                NativeCodeBlock(code: code, actions: actions)
            }
        }
    }
    @ViewBuilder private func reportBlock(_ block: JSONValue) -> some View {
        switch block.nativeString("type") {
        case "field":
            VStack(alignment: .leading) {
                Text(block.nativeString("label") ?? "").font(.headline)
                values(block.nativeArray("values"))
            }
        case "badges":
            VStack(alignment: .leading) {
                Text(block.nativeString("label") ?? "").font(.headline)
                values(block.nativeArray("items"))
            }
        case "table":
            ScrollView(.horizontal) {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("")
                        ForEach(Array(block.nativeArray("columns").enumerated()), id: \.offset) { _, column in Text(column.string ?? "").font(.headline) }
                    }
                    ForEach(Array(block.nativeArray("rows").enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.nativeString("label") ?? "")
                            ForEach(Array(row.nativeArray("cells").enumerated()), id: \.offset) { _, cell in reportValue(cell) }
                        }
                    }
                }
            }
        case "note": Text(block.nativeString("text") ?? "").textSelection(.enabled)
        default: NativeFailureView(failure: .init(code: "INVALID_DATA", message: "Unknown report block"))
        }
    }
    private func values(_ values: [JSONValue]) -> some View {
        VStack(alignment: .leading) { ForEach(Array(values.enumerated()), id: \.offset) { _, value in reportValue(value) } }
    }
    private func reportValue(_ value: JSONValue) -> some View {
        let tone = value.nativeString("tone")
        return Label(value.nativeString("text") ?? "", systemImage: tone == "Good" ? "checkmark.circle" : tone == "Bad" ? "xmark.circle" : tone == "Warn" ? "exclamationmark.triangle" : "minus")
            .foregroundStyle(tone == "Good" ? Color.green : tone == "Bad" ? Color.red : tone == "Warn" ? Color.orange : Color.primary)
            .textSelection(.enabled)
    }
}
