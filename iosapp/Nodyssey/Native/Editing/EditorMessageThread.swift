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
            EditorMessageHistory(scope: .init(generation: app.generation, uid: uid), messages: messages, quote: model.quote)
                .id(EditorMessageFollowState.Scope(generation: app.generation, uid: uid))
            if store.isLoading { ProgressView() }
        }
        .task(id: "\(app.generation):\(uid):\(retry)") { await store.observe(app, "messages.thread", ["uid": .integer(uid)]) }
    }
}

private struct EditorMessageGeometry: Equatable, Sendable {
    let observation: UUID
    let sample: EditorMessageFollowState.Sample
}

private struct EditorMessageGeometryKey: PreferenceKey {
    static let defaultValue: EditorMessageGeometry? = nil
    static func reduce(value: inout EditorMessageGeometry?, nextValue: () -> EditorMessageGeometry?) {
        if let next = nextValue() { value = next }
    }
}

private struct EditorMessageHistory: View {
    let scope: EditorMessageFollowState.Scope
    let messages: [JSONValue]
    let quote: (String) -> Void
    @StateObject private var follow = EditorMessageFollowObservation()
    private var observation: UUID { follow.observation }
    private var lastID: String? { messages.last?["id"]?.string }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages.indices, id: \.self) { index in
                            if let id = messages[index]["id"]?.string {
                                EditorMessageRow(value: messages[index], quote: quote).id(id)
                            }
                        }
                    }
                    .padding()
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: EditorMessageGeometryKey.self, value: EditorMessageGeometry(
                                observation: observation,
                                sample: .init(scope: scope, lastID: lastID,
                                              top: Double(content.frame(in: .named(observation)).minY),
                                              height: Double(content.size.height), viewport: Double(viewport.size.height))))
                        }.allowsHitTesting(false)
                    }
                }
                .coordinateSpace(name: observation)
                // iOS 16 has no scroll-position/scroll-geometry API. Observe the
                // original content's real frame, never LazyVStack row appearances.
                // Content identity and geometry arrive together, avoiding an
                // onChange/new-layout ordering race that would lose follow intent.
                .onPreferenceChange(EditorMessageGeometryKey.self) { value in
                    guard let value, value.observation == observation, value.sample.scope == scope else { return }
                    if follow.update(value.sample, observation: value.observation), let id = value.sample.lastID {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if follow.presentation != .following, let id = lastID {
                        Button(action: follow.makeReturnAction(
                            targetID: id,
                            scope: scope,
                            observation: observation,
                            scrollTo: { proxy.scrollTo($0, anchor: .bottom) }
                        )) {
                            Label(PCL(follow.presentation == .newMessages ? "newMessagesReturnToLatest" : "returnToLatestMessages"),
                                  systemImage: follow.presentation == .newMessages ? "arrow.down.to.line.circle.fill" : "arrow.down.to.line")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding()
                    }
                }
            }
        }
        .onAppear { follow.activate() }
        .onDisappear { follow.revoke() }
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
