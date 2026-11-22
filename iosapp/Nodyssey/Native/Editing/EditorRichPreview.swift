import SwiftUI
import NodysseyNativeCore

/// Preview never silently casts votes. The marker opens a real, read-only server snapshot.
struct EditorRichPreview: View {
    @EnvironmentObject private var app: NativeAppModel
    let nodes: [NativeRichNode]
    var expandsWidth = true
    @State private var vote: EditorPreviewVote?
    var body: some View {
        NativeRichTextView(nodes: nodes, actions: editorRichActions(app, onVote: { vote = EditorPreviewVote(id: $0) }),
                           expandsWidth: expandsWidth)
            .sheet(item: $vote) { value in
                NavigationStack { EditorPollSnapshot(id: value.id) }
            }
            .onChange(of: app.generation) { _ in vote = nil }
    }
}
private struct EditorPreviewVote: Identifiable { let id: Int64 }
private struct EditorPollSnapshot: View {
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    let id: Int64
    @StateObject private var store = NativeStore()
    @State private var retry = 0
    var body: some View {
        List {
            if store.isLoading { ProgressView() }
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            if let title = store.value["title"]?.string { Text(title).font(.headline) }
            ForEach(Array((store.value["items"]?.array ?? []).enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item["text"]?.string ?? "")
                    Spacer()
                    if let count = item["count"]?.int { Text(String(count)) }
                    if item["voted"]?.bool == true { Image(systemName: "checkmark") }
                }
            }
        }
        .navigationTitle(EL("preview"))
        .toolbar { Button(EL("close")) { dismiss() } }
        .task(id: "\(app.generation):\(retry)") { await store.load(app, "vote.get", ["voteId": .integer(id)]) }
    }
}
