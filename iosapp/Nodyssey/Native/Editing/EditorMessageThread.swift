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
    private var peerName: String { store.value["userName"]?.string ?? String(uid) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            EditorMessageHistory(scope: .init(generation: app.generation, uid: uid),
                                 messages: messages, peer: peerName, quote: model.quote)
                .id(EditorMessageFollowState.Scope(generation: app.generation, uid: uid))
            if store.isLoading { ProgressView() }
        }
        .task(id: "\(app.generation):\(uid):\(retry)") { await store.observe(app, "messages.thread", ["uid": .integer(uid)]) }
    }

    /// Peer identity and the two thread actions read as one conversation header
    /// instead of a row of equal-weight text buttons.
    private var header: some View {
        HStack(spacing: 10) {
            Button { app.open("UserSpace", ["uid": .integer(uid)]) } label: {
                HStack(spacing: 8) {
                    ChatAvatar(name: peerName, size: 26)
                    Text(peerName).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                Task {
                    do { _ = try await app.request("messages.refresh"); retry += 1 }
                    catch { model.report(error) }
                }
            } label: {
                Image(systemName: "arrow.clockwise").frame(minWidth: 30, minHeight: 30)
            }.accessibilityLabel(Text(EL("refresh")))
            Button {
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
            } label: {
                Image(systemName: "checkmark.circle").frame(minWidth: 30, minHeight: 30)
            }
            .disabled(reading || (store.value["unreadIds"]?.array ?? []).isEmpty)
            .accessibilityLabel(Text(EL("markRead")))
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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

/// One row's presentation, derived once so grouping cannot disagree with the bubble.
private struct EditorMessageItem: Identifiable {
    let value: JSONValue
    let mine: Bool
    /// Last bubble of one sender's run: carries the tail, incoming avatar and time.
    let runEnd: Bool
    let startsRun: Bool
    let dayLabel: String?
    var id: String? { value["id"]?.string }
}

private func editorMessageDay(_ text: String?) -> String? {
    guard let text else { return nil }
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0].contains("-") else { return nil }
    return String(parts[0])
}

private func editorMessageClock(_ text: String?) -> String? {
    guard let text else { return nil }
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    return parts.count == 2 ? String(parts[1]) : text
}

private struct EditorMessageHistory: View {
    let scope: EditorMessageFollowState.Scope
    let messages: [JSONValue]
    let peer: String
    let quote: (String) -> Void
    @StateObject private var follow = EditorMessageFollowObservation()
    private var observation: UUID { follow.observation }
    private var lastID: String? { messages.last?["id"]?.string }

    private var items: [EditorMessageItem] {
        messages.indices.map { index in
            let value = messages[index]
            let mine = value["isMine"]?.bool == true
            let day = editorMessageDay(value["sentAtText"]?.string)
            func belongsToRun(_ neighbor: Int) -> Bool {
                guard messages.indices.contains(neighbor) else { return false }
                let other = messages[neighbor]
                return (other["isMine"]?.bool == true) == mine &&
                    editorMessageDay(other["sentAtText"]?.string) == day
            }
            let previousDay = index > 0 ? editorMessageDay(messages[index - 1]["sentAtText"]?.string) : nil
            return EditorMessageItem(value: value, mine: mine, runEnd: !belongsToRun(index + 1),
                                     startsRun: !belongsToRun(index - 1),
                                     dayLabel: day != nil && day != previousDay ? day : nil)
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(items) { item in
                            if let day = item.dayLabel {
                                Text(day)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                            if let id = item.id {
                                EditorMessageBubble(value: item.value, mine: item.mine, runEnd: item.runEnd,
                                                    peer: peer, maxWidth: max(160, viewport.size.width * 0.76),
                                                    quote: quote)
                                    .padding(.top, item.startsRun && item.dayLabel == nil ? 8 : 1)
                                    .id(id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
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

/// The sender-side bottom corner is tight, so a run of messages reads as one
/// column without a separate tail view that would clip rich content.
private struct ChatBubbleShape: Shape {
    let mine: Bool
    /// Telegram keeps a run of messages reading as one column and only the last
    /// bubble takes the sender-side tail.
    var tail: Bool = true

    func path(in rect: CGRect) -> Path {
        let big = min(18, rect.height / 2)
        let small = tail ? min(6, rect.height / 2) : big
        let topLeft = big, topRight = big
        let bottomRight = mine ? small : big
        let bottomLeft = mine ? big : small
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight), radius: topRight,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight), radius: bottomRight,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft), radius: bottomLeft,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft), radius: topLeft,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct ChatAvatar: View {
    let name: String
    var size: CGFloat = 28

    private var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    var body: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.18))
            .overlay(Text(initial).font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.accentColor))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct EditorMessageBubble: View {
    @EnvironmentObject private var app: NativeAppModel
    let value: JSONValue
    let mine: Bool
    let runEnd: Bool
    let peer: String
    let maxWidth: CGFloat
    let quote: (String) -> Void
    @State private var nodes: [NativeRichNode]?
    @State private var failure: NativeFailure?
    @State private var retry = 0

    private var text: String { value["content"]?.string ?? "" }
    private var clock: String? { editorMessageClock(value["sentAtText"]?.string) }
    private var usesSolidFill: Bool { mine && value["isMarkdown"]?.bool != true }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            // Telegram only shows a face beside the last bubble of a run; an
            // empty slot keeps the column aligned for the rest.
            if mine {
                Spacer(minLength: 0)
            } else {
                if runEnd { ChatAvatar(name: peer, size: 26) } else { Color.clear.frame(width: 26, height: 1) }
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                bubble
                    .frame(maxWidth: maxWidth, alignment: mine ? .trailing : .leading)
                if let failure { Text(failure.message).font(.caption2).foregroundStyle(.secondary) }
            }
            if !mine { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .task(id: "\(app.generation):\(retry):\(text)") {
            nodes = nil; failure = nil
            guard value["isMarkdown"]?.bool == true, let raw = value["content"]?.string else { return }
            do {
                let json = try await app.request("editor.preview", ["body": .string(raw)])
                let parsed = try JSONDecoder().decode([NativeRichNode].self, from: JSONEncoder().encode(json))
                try Task.checkCancellation()
                nodes = parsed
            } catch is CancellationError { }
            catch { failure = error as? NativeFailure ?? NativeFailure(code: "INVALID_DATA", message: "Message could not be decoded") }
        }
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: 3) {
            content
            if runEnd, let clock {
                HStack(spacing: 3) {
                    Text(clock)
                    if mine { Image(systemName: "checkmark") }
                }
                .font(.caption2)
                .foregroundStyle(usesSolidFill ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .background {
            ChatBubbleShape(mine: mine, tail: runEnd)
                // Rich bodies keep the light tint: their own text colours are not
                // ours to invert, so a solid fill would make them unreadable.
                .fill(mine ? AnyShapeStyle(value["isMarkdown"]?.bool == true ? Color.accentColor.opacity(0.18) : Color.accentColor)
                      : AnyShapeStyle(.quaternary))
        }
        .contentShape(ChatBubbleShape(mine: mine, tail: runEnd))
        .contextMenu { Button(EL("quote")) { quote(text) } }
    }

    @ViewBuilder private var content: some View {
        if value["isMarkdown"]?.bool == true {
            if let nodes { EditorRichPreview(nodes: nodes) }
            else if failure != nil { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            else { ProgressView().controlSize(.small) }
        } else {
            Text(text)
                .foregroundStyle(usesSolidFill ? Color.white : Color.primary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
