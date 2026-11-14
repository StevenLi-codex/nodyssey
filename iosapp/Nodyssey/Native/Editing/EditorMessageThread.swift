import SwiftUI
import NodysseyNativeCore

struct EditorMessageThread: View {
    @EnvironmentObject private var app: NativeAppModel
    let uid: Int64
    @ObservedObject var model: EditorViewModel
    @StateObject private var store = NativeStore()
    @State private var retry = 0
    @State private var reading = false
    private var messages: [JSONValue] { store.value["messages"]?.array ?? [] }

    var body: some View {
        VStack {
            HStack {
                Button(store.value["userName"]?.string ?? String(uid)) { app.open("UserSpace", ["uid": .integer(uid)]) }
                Spacer()
                Button(EL("refresh")) {
                    Task {
                        do { _ = try await app.request("messages.refresh"); retry += 1 }
                        catch { model.report(error) }
                    }
                }
                Button(EL("markRead")) {
                    guard let ids = store.value["unreadIds"]?.array, !ids.isEmpty else { return }
                    reading = true
                    Task {
                        defer { reading = false }
                        do {
                            _ = try await app.request("messages.read", ["messageIds": .array(ids)])
                            // Mutation invalidates observer. Re-read exact authoritative thread too.
                            let value = try await app.request("messages.thread", ["uid": .integer(uid)])
                            store.value = value
                        } catch { model.report(error) }
                    }
                }.disabled(reading || (store.value["unreadIds"]?.array ?? []).isEmpty)
            }.padding(.horizontal)
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages.indices, id: \.self) { index in
                            if let id = messages[index]["id"]?.string {
                                let value = messages[index]
                                EditorMessageRow(value: value, quote: { text in
                                    model.quote(text)
                                }).id(id)
                            }
                        }
                    }.padding()
                }
                .onChange(of: messages.last?["id"]?.string) { id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            if store.isLoading { ProgressView() }
        }
        .task(id: "\(app.generation):\(retry)") { await store.observe(app, "messages.thread", ["uid": .integer(uid)]) }
    }
}

private struct EditorMessageRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let value: JSONValue
    let quote: (String) -> Void
    @State private var nodes: [NativeRichNode]?
    @State private var failure: NativeFailure?
    @State private var retry = 0
    var body: some View {
        HStack {
            if value["isMine"]?.bool == true { Spacer(minLength: 30) }
            VStack(alignment: .leading) {
                if let time = value["sentAtText"]?.string { Text(time).font(.caption).foregroundStyle(.secondary) }
                if value["isMarkdown"]?.bool == true {
                    if let nodes { EditorRichPreview(nodes: nodes) }
                    else if let failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
                    else { ProgressView() }
                } else { Text(value["content"]?.string ?? "").textSelection(.enabled) }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .contextMenu { Button(EL("quote")) { quote(value["content"]?.string ?? "") } }
            if value["isMine"]?.bool != true { Spacer(minLength: 30) }
        }
        .task(id: "\(app.generation):\(retry):\(value["content"]?.string ?? "")") {
            nodes = nil; failure = nil
            guard value["isMarkdown"]?.bool == true, let text = value["content"]?.string else { return }
            do {
                let json = try await app.request("editor.preview", ["body": .string(text)])
                let parsed = try JSONDecoder().decode([NativeRichNode].self, from: JSONEncoder().encode(json))
                try Task.checkCancellation()
                nodes = parsed
            } catch is CancellationError { }
            catch { failure = error as? NativeFailure ?? NativeFailure(code: "INVALID_DATA", message: "Message could not be decoded") }
        }
    }
}
