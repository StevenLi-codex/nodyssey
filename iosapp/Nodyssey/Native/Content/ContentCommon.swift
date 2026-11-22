import SwiftUI
import NodysseyNativeCore

@MainActor enum NativeContentScreens {
    static func make(destination: NativeDestination) -> AnyView? {
        switch destination.route {
        case "PostList": return AnyView(ContentPostList())
        case "Search": return AnyView(ContentSearch(initialQuery: destination.arguments["query"]?.string))
        case "Notifications": return AnyView(ContentNotifications(initialGroup: destination.arguments["group"]?.string))
        case "PostDetail":
            guard let id = destination.arguments["postId"]?.int, id > 0 else {
                return AnyView(NativeFailureView(failure: NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid post identity")))
            }
            return AnyView(ContentPostDetail(postID: id, initialFloor: destination.arguments["floor"]?.string, initialPage: destination.arguments["page"]?.int, preview: destination.arguments["preview"]))
        default: return nil
        }
    }
}

extension NativeAppModel: ContentCommandContext {}

struct ContentCommandStatus: View {
    @ObservedObject var command: ContentCommand
    var body: some View {
        if command.busy { ProgressView() }
        if let failure = command.failure { NativeFailureView(failure: failure) }
    }
}

struct ContentStoreStatus: View {
    @ObservedObject var store: NativeStore
    var initialLoading = false
    var silentRefresh = false
    var retry: () -> Void
    var body: some View {
        if store.isLoading || (initialLoading && !store.hasValue && store.value == .null && store.failure == nil) { NativeBusyView() }
        else if store.isRefreshing && !silentRefresh { ProgressView().controlSize(.small) }
        if let failure = store.failure { NativeFailureView(failure: failure, retry: retry) }
    }
}

/// Neutral reading surfaces inherit the user's existing theme accent.
struct ContentSurface: View {
    var canvas = false
    var body: some View {
        NativePageSurface(canvas: canvas)
    }
}

struct ContentAvatar: View {
    let value: JSONValue
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.10))
            if let url = value.nativeString("avatarUrl"), !url.isEmpty {
                NativeRemoteImage(url: url, aspectFit: true)
            } else {
                Image(systemName: "person.fill").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct ContentPostRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let value: JSONValue
    var openPost: (() -> Void)? = nil
    var openAuthor: ((Int64) -> Void)? = nil
    var transitionSource: NativePostTransition.Source? = nil
    var previewItem: ContentPostPreviewItem? = nil
    var returnCardID: Int64? = nil
    var body: some View {
        let summary = value["summary"] ?? value
        postAction {
            card(summary)
                .padding(.horizontal, NativeFeedLayout.horizontalInset).padding(.vertical, 4)
                // The shape belongs to the action's label, including its padding.
                .contentShape(Rectangle())
        }
        .overlay(alignment: .topLeading) {
            if summary.nativeBool("isPinned") != true,
               let uid = summary.nativeInt("authorUid"), uid > 0, let openAuthor {
                // Sibling of the post Button, not a Button nested in its label.
                // Match the header's layout so long names cannot cover the board/badges.
                HStack(spacing: 6) {
                    Button { openAuthor(uid) } label: {
                        author(summary).padding(.top, 8).padding(.bottom, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("native.account.quick_card.title", tableName: "Account"))
                    board(summary).hidden()
                    Spacer(minLength: 0)
                    ContentPostBadges(summary: summary).hidden()
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 28).padding(.top, 4)
            }
        }
        .nativePostTransitionSource(transitionSource)
        #if os(iOS)
        .background {
            if let returnCardID {
                NativePostReturnCard(postID: returnCardID)
                    .padding(.horizontal, NativeFeedLayout.horizontalInset)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        #endif
    }
    private func card(_ summary: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if summary.nativeBool("isPinned") == true {
                HStack(spacing: 8) {
                    Image(systemName: "pin.fill").foregroundStyle(.tint)
                        .accessibilityLabel(Text(String(localized: "content.pinned", table: "Content")))
                    Text(summary.nativeString("title") ?? "")
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }.font(.subheadline).frame(minHeight: 44)
            } else {
                HStack(spacing: 6) {
                    if let uid = summary.nativeInt("authorUid"), uid > 0, openAuthor != nil {
                        author(summary).hidden()
                    } else { author(summary) }
                    board(summary)
                    Spacer(minLength: 0)
                    ContentPostBadges(summary: summary)
                }.font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary.nativeString("title") ?? "")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(value.nativeBool("isRead") == true ? .secondary : .primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { replies(summary); lastReply(summary); Spacer(minLength: 0); views(summary) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 10) { replies(summary); views(summary) }
                            lastReply(summary)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, summary.nativeBool("isPinned") == true ? 0 : 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background { ContentPostCardSurface().allowsHitTesting(false) }
    }
    @ViewBuilder private func postAction<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        if let openPost {
            Button(action: openPost) {
                label().background {
                    if let previewItem {
                        ContentPostPreviewInteraction(item: previewItem)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }.buttonStyle(NativeCardPressStyle())
                .accessibilityIdentifier("native.feed.post")
        }
        else { label() }
    }
    private func author(_ summary: JSONValue) -> some View {
        HStack(spacing: 5) {
            ContentAvatar(value: summary, size: 20)
            Text(summary.nativeString("authorName") ?? "").fontWeight(.semibold)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
    }
    @ViewBuilder private func lastReply(_ summary: JSONValue) -> some View {
        if let time = summary.nativeString("lastActiveText") {
            // This is the last reply's time, not the author's posting time.
            HStack(spacing: 4) {
                if let name = summary.nativeString("lastCommenterName") { Text(name) }
                Text(time)
            }
        }
    }
    @ViewBuilder private func board(_ summary: JSONValue) -> some View {
        if let category = summary.nativeString("categoryTitle"), !category.isEmpty {
            Text(category).fontWeight(.medium).foregroundStyle(.tint)
        }
    }
    @ViewBuilder private func replies(_ summary: JSONValue) -> some View {
        if let comments = summary.nativeInt("commentCount") { Label("\(comments)", systemImage: "bubble.right") }
        if let count = value.nativeInt("newCommentCount"), count > 0 { Text("+\(count)").foregroundStyle(.tint) }
    }
    @ViewBuilder private func views(_ summary: JSONValue) -> some View {
        if let views = summary.nativeInt("viewCount") { Label("\(views)", systemImage: "eye") }
    }
}

/// Match the My-page group's continuous boundary/depth, but keep reading opaque.
private struct ContentPostCardSurface: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: NativeFeedLayout.cardCornerRadius, style: .continuous)
    var body: some View {
        ContentSurface()
            .overlay { shape.fill(.tint).opacity(0.025) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.25 : 0.08), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
            .accessibilityHidden(true)
    }
}

struct ContentPostBadges: View {
    let summary: JSONValue
    var body: some View {
        if summary.nativeBool("isPinned") == true {
            Image(systemName: "pin.fill").foregroundStyle(.tint).accessibilityLabel(Text("post_badge_pinned"))
        }
        if summary.nativeBool("isAwarded") == true {
            Image(systemName: "rosette").foregroundStyle(.tint).accessibilityLabel(Text("post_badge_awarded"))
        }
        if summary.nativeBool("isLocked") == true {
            Image(systemName: "lock.fill").accessibilityLabel(Text(String(localized: "content.locked", table: "Content")))
        }
        if let level = summary.nativeInt("lockLevel"), level > 0 { Label("\(level)", systemImage: "lock.shield") }
    }
}

/// Search is intentionally avatar-free and highlights the submitted literal, not the edit buffer.
struct ContentSearchPostRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let value: JSONValue
    let query: String
    var body: some View {
        let summary = value["summary"] ?? value
        VStack(alignment: .leading, spacing: 6) {
            Text(contentHighlighted(summary.nativeString("title") ?? "", query: query))
                .font(.body.weight(.semibold))
                .foregroundStyle(value.nativeBool("isRead") == true ? .secondary : .primary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { metadata(summary) }
                VStack(alignment: .leading, spacing: 4) { metadata(summary) }
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(ContentSurface()).contentShape(Rectangle())
    }
    @ViewBuilder private func metadata(_ summary: JSONValue) -> some View {
        if let board = summary.nativeString("categoryTitle") { Text(board).foregroundStyle(.tint) }
        Text(summary.nativeString("authorName") ?? "")
        if let time = summary.nativeString("lastActiveText") { Text(time) }
        ContentPostBadges(summary: summary)
        if let count = summary.nativeInt("commentCount") { Label("\(count)", systemImage: "bubble.right") }
        if let count = value.nativeInt("newCommentCount"), count > 0 { Text("+\(count)").foregroundStyle(.tint) }
    }
}

func contentHighlighted(_ text: String, query: String) -> AttributedString {
    var result = AttributedString(text)
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return result }
    var cursor = text.startIndex
    while cursor < text.endIndex, let range = text.range(of: needle, options: .caseInsensitive, range: cursor..<text.endIndex) {
        if let lower = AttributedString.Index(range.lowerBound, within: result),
           let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].backgroundColor = Color.accentColor.opacity(0.18)
        }
        cursor = range.upperBound
    }
    return result
}

struct ContentSearchUserRow: View {
    let value: JSONValue
    let query: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ContentAvatar(value: value, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(contentHighlighted(value.nativeString("name") ?? "", query: query)).font(.subheadline.weight(.semibold))
                    if let level = value.nativeInt("level") { Text(String(format: NSLocalizedString("credit_level", comment: "").replacingOccurrences(of: "%1$d", with: "%1$lld"), level)).font(.caption) }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).foregroundStyle(.primary)
    }
    private var details: String {
        var parts: [String] = []
        if let uid = value.nativeInt("uid") { parts.append("UID \(uid)") }
        for (field, key) in [("topicCount", "search_user_topics"), ("commentCount", "search_user_comments")] {
            if let count = value.nativeInt(field) { parts.append(String(format: NSLocalizedString(key, comment: "").replacingOccurrences(of: "%1$d", with: "%1$lld"), count)) }
        }
        if let bio = value.nativeString("bio"), !bio.isEmpty { parts.append(bio) }
        else if let joined = value.nativeString("joinedText") { parts.append(String(format: NSLocalizedString("search_user_joined", comment: ""), joined)) }
        return parts.joined(separator: " · ")
    }
}

struct ContentPageEntry: View {
    @Binding var text: String
    var submit: (Int64) -> Void
    var body: some View {
        HStack {
            TextField(String(localized: "content.page", table: "Content"), text: $text)
                .frame(minHeight: 44)
                .onSubmit { if let page = Int64(text), page > 0 { submit(page) } }
            Button(String(localized: "content.go", table: "Content")) { if let page = Int64(text), page > 0 { submit(page) } }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(Int64(text).map { $0 < 1 || $0 > Int64(Int32.max) } ?? true)
        }
    }
}
