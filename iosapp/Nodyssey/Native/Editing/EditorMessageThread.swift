import Foundation
import SwiftUI
import NodysseyNativeCore

struct EditorMessageThread: View {
    @EnvironmentObject private var app: NativeAppModel
    let uid: Int64
    @ObservedObject var model: EditorViewModel
    @Binding var showTools: Bool
    @StateObject private var store = NativeStore()
    @State private var retry = 0
    @State private var reading = false
    @Environment(\.colorScheme) private var colorScheme
    private var messages: [JSONValue] { store.value["messages"]?.array ?? [] }
    private var peerName: String { store.value["userName"]?.string ?? String(uid) }
    private var peerAvatar: String? { store.value["avatarUrl"]?.string }
    private var unreadIds: [JSONValue] { store.value["unreadIds"]?.array ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = store.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            EditorMessageHistory(scope: .init(generation: app.generation, uid: uid),
                                 messages: messages, quote: model.quote)
                .id(EditorMessageFollowState.Scope(generation: app.generation, uid: uid))
                .background(ChatPalette.canvas(colorScheme))
            if store.isLoading { ProgressView() }
        }
        .toolbar {
            ToolbarItem(placement: .principal) { peerTitle }
            ToolbarItem(placement: .primaryAction) { threadMenu }
        }
        .modifier(EditorMessageBarBackground(scheme: colorScheme))
        .task(id: "\(app.generation):\(uid):\(retry)") {
            await store.observe(app, "messages.thread", ["uid": .integer(uid)])
        }
    }

    /// The peer's name and face belong in the bar, not in a second header row
    /// under it: tapping either opens the same space.
    private var peerTitle: some View {
        Button { app.open("UserSpace", ["uid": .integer(uid)]) } label: {
            HStack(spacing: 8) {
                ChatAvatar(name: peerName, url: peerAvatar, size: 28)
                Text(peerName).font(.headline).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(peerName))
    }

    private var threadMenu: some View {
        Menu {
            Button {
                model.focus.handoff {
                    if model.previewing { model.previewing = false }
                    else { Task { await model.showPreview() } }
                }
            } label: {
                Label(EL(model.previewing ? "edit" : "preview"),
                      systemImage: model.previewing ? "pencil" : "eye")
            }
            Toggle(isOn: $showTools) {
                Label(EL("markdown"), systemImage: "textformat")
            }
            Divider()
            Button { Task { await refreshThread() } } label: {
                Label(EL("refresh"), systemImage: "arrow.clockwise")
            }
            Button { markRead() } label: {
                Label(EL("markRead"), systemImage: "checkmark.circle")
            }
            .disabled(reading || unreadIds.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(PCL("moreTools")))
    }

    private func refreshThread() async {
        do {
            _ = try await app.request("messages.refresh")
            retry += 1
        } catch {
            model.report(error)
        }
    }

    private func markRead() {
        guard !unreadIds.isEmpty else { return }
        reading = true
        Task {
            defer { reading = false }
            do {
                _ = try await app.request("messages.read", ["messageIds": .array(unreadIds)])
                // The mutation invalidates the observer; read the exact thread again.
                let value = try await app.request("messages.thread", ["uid": .integer(uid)])
                store.value = value
            } catch {
                model.report(error)
            }
        }
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
    let joinsPrevious: Bool
    let joinsNext: Bool
    let dayLabel: String?
    let topSpacing: CGFloat
    var id: String? { value["id"]?.string }
}

/// Conversation palette from the handoff artboard: a cool grey canvas and
/// white incoming bubbles. Outgoing bubbles keep the card and carry a pale
/// accent wash instead of a solid fill, so rich text stays readable.
private enum ChatPalette {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(.sRGB, white: 0.07) : Color(.sRGB, red: 0.949, green: 0.949, blue: 0.973)
    }
    static func incoming(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(.sRGB, white: 0.14) : .white
    }
}

private func editorMessageDate(_ value: JSONValue) -> Date? {
    if let millis = value["sentAtMillis"]?.int {
        return Date(timeIntervalSince1970: Double(millis) / 1_000)
    }
    guard let text = value["sentAtText"]?.string else { return nil }
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2 else { return nil }
    let dateParts = parts[0].split(separator: "-").compactMap { Int($0) }
    let timeParts = parts[1].split(separator: ":").compactMap { Int($0) }
    guard dateParts.count == 3, timeParts.count >= 2 else { return nil }
    var components = DateComponents()
    components.year = dateParts[0]
    components.month = dateParts[1]
    components.day = dateParts[2]
    components.hour = timeParts[0]
    components.minute = timeParts[1]
    return Calendar.current.date(from: components)
}

private func editorMessageDay(_ value: JSONValue) -> Date? {
    guard let date = editorMessageDate(value) else { return nil }
    return Calendar.current.startOfDay(for: date)
}

private func editorMessageDayKey(_ value: JSONValue) -> String? {
    if let day = editorMessageDay(value) { return String(day.timeIntervalSince1970) }
    return value["sentAtText"]?.string?.split(separator: " ").first.map(String.init)
}

private func editorMessageDayLabel(_ value: JSONValue) -> String? {
    if let date = editorMessageDate(value) {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let style: Date.FormatStyle = sameYear
            ? .dateTime.month(.abbreviated).day()
            : .dateTime.year().month(.abbreviated).day()
        return date.formatted(style)
    }
    return value["sentAtText"]?.string?.split(separator: " ").first.map(String.init)
}

private func editorMessageClock(_ value: JSONValue) -> String? {
    if let date = editorMessageDate(value) {
        return date.formatted(.dateTime.hour().minute())
    }
    guard let text = value["sentAtText"]?.string else { return nil }
    let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    return parts.count == 2 ? String(parts[1]) : text
}

private struct EditorMessageHistory: View {
    let scope: EditorMessageFollowState.Scope
    let messages: [JSONValue]
    let quote: (String) -> Void
    @StateObject private var follow = EditorMessageFollowObservation()
    private var observation: UUID { follow.observation }
    private var lastID: String? { messages.last?["id"]?.string }

    private var items: [EditorMessageItem] {
        messages.indices.map { index in
            let value = messages[index]
            let mine = value["isMine"]?.bool == true
            let date = editorMessageDate(value)
            func belongsToRun(_ neighbor: Int) -> Bool {
                guard messages.indices.contains(neighbor) else { return false }
                let other = messages[neighbor]
                guard (other["isMine"]?.bool == true) == mine else { return false }
                guard let date, let otherDate = editorMessageDate(other) else {
                    return editorMessageDayKey(other) != nil &&
                        editorMessageDayKey(other) == editorMessageDayKey(value)
                }
                guard Calendar.current.isDate(date, inSameDayAs: otherDate) else { return false }
                return abs(date.timeIntervalSince(otherDate)) <= 300
            }
            let day = editorMessageDay(value)
            let previousDay = index > 0 ? editorMessageDay(messages[index - 1]) : nil
            let label = day != nil && day != previousDay ? editorMessageDayLabel(value) : nil
            let joinsPrevious = belongsToRun(index - 1)
            return EditorMessageItem(value: value, mine: mine, joinsPrevious: joinsPrevious,
                                     joinsNext: belongsToRun(index + 1), dayLabel: label,
                                     topSpacing: joinsPrevious ? 2 : (label == nil ? 8 : 0))
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in
                            if let day = item.dayLabel {
                                Text(day)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            if let id = item.id {
                                EditorMessageBubble(value: item.value, mine: item.mine,
                                                    joinsPrevious: item.joinsPrevious,
                                                    joinsNext: item.joinsNext, quote: quote)
                                    .padding(.top, item.topSpacing)
                                    .id(id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
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
                .scrollDismissesKeyboard(.interactively)
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
                .overlay(alignment: .bottom) {
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
                        .padding(.bottom, 8)
                    }
                }
            }
        }
        .onAppear { follow.activate() }
        .onDisappear { follow.revoke() }
    }
}

/// iNod's conversation shape: 16pt corners, with only the corners that touch
/// the same sender's previous or next bubble pulled in to 6pt.
private struct ChatBubbleShape: Shape {
    let mine: Bool
    let joinsPrevious: Bool
    let joinsNext: Bool

    func path(in rect: CGRect) -> Path {
        let large = min(16, min(rect.width / 2, rect.height / 2))
        let small = min(5, min(rect.width / 2, rect.height / 2))
        let top = joinsPrevious ? small : large
        let bottom = joinsNext ? small : large
        let topLeft = mine ? large : top
        let bottomLeft = mine ? large : bottom
        let topRight = mine ? top : large
        let bottomRight = mine ? bottom : large
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
    var url: String? = nil
    var size: CGFloat = 28

    private var initial: String { name.first.map { String($0).uppercased() } ?? "?" }

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            if let url, !url.isEmpty {
                NativeRemoteImage(url: url, aspectFit: true)
            } else {
                Text(initial).font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct EditorMessageBubble: View {
    @EnvironmentObject private var app: NativeAppModel
    let value: JSONValue
    let mine: Bool
    let joinsPrevious: Bool
    let joinsNext: Bool
    let quote: (String) -> Void
    @State private var nodes: [NativeRichNode]?
    @State private var failure: NativeFailure?
    @State private var retry = 0
    @Environment(\.colorScheme) private var colorScheme

    private var text: String { value["content"]?.string ?? "" }
    private var clock: String? { editorMessageClock(value) }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            bubble
                .frame(maxWidth: 500, alignment: mine ? .trailing : .leading)
            if let failure { Text(failure.message).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        // Leave the same 52pt gutter iNod uses, so the conversation reads as
        // two columns without an avatar in every incoming run.
        .padding(mine ? .leading : .trailing, 52)
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
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                ChatBubbleShape(mine: mine, joinsPrevious: joinsPrevious, joinsNext: joinsNext)
                    .fill(ChatPalette.incoming(colorScheme))
                    .overlay {
                        if mine {
                            ChatBubbleShape(mine: true, joinsPrevious: joinsPrevious, joinsNext: joinsNext)
                                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.13))
                        }
                    }
            }
            .contentShape(ChatBubbleShape(mine: mine, joinsPrevious: joinsPrevious, joinsNext: joinsNext))
            .contextMenu { Button(EL("quote")) { quote(text) } }
    }

    @ViewBuilder private var content: some View {
        if value["isMarkdown"]?.bool == true {
            VStack(alignment: .trailing, spacing: 3) {
                // Show the raw Markdown while the rich tree loads. A spinner
                // alone would shrink a whole message to a timestamp-high bubble.
                if let nodes {
                    ViewThatFits(in: .horizontal) {
                        EditorRichPreview(nodes: nodes, expandsWidth: false)
                            .fixedSize(horizontal: true, vertical: true)
                        EditorRichPreview(nodes: nodes, expandsWidth: false)
                    }
                } else { Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if let clock {
                    Text(clock).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            plainBody
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The clock sits on the last text line, the way iNod places its trailing
    /// label, instead of taking a second line under every bubble.
    private var plainBody: Text {
        let body = Text(text)
        guard let clock else { return body }
        return body + Text("  \(clock)").font(.caption2).foregroundColor(.secondary)
    }
}

/// A conversation scrolls under its bar; leave a real material there so the
/// oldest visible message cannot read through the peer's name.
private struct EditorMessageBarBackground: ViewModifier {
    let scheme: ColorScheme

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.visible, for: .navigationBar)
                .toolbarBackground(ChatPalette.canvas(scheme), for: .navigationBar)
        } else {
            content
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(ChatPalette.canvas(scheme), for: .navigationBar)
        }
        #else
        content
        #endif
    }
}
