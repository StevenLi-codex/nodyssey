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
    var retry: () -> Void
    var body: some View {
        if store.isLoading { NativeBusyView() }
        if let failure = store.failure { NativeFailureView(failure: failure, retry: retry) }
    }
}

/// Neutral surfaces inherit the user's accent; the reference's orange is not a theme override.
struct ContentSurface: View {
    @Environment(\.colorScheme) private var scheme
    var canvas = false
    var body: some View {
        (scheme == .dark
            ? (canvas ? Color(.sRGB, white: 0.035, opacity: 1) : Color(.sRGB, white: 0.085, opacity: 1))
            : (canvas ? Color(.sRGB, white: 0.95, opacity: 1) : Color.white))
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
    let value: JSONValue
    var body: some View {
        let summary = value["summary"] ?? value
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ContentAvatar(value: summary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.nativeString("authorName") ?? "").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if let time = summary.nativeString("lastActiveText") {
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if summary.nativeBool("isPinned") == true {
                    Image(systemName: "pin.fill").foregroundStyle(.tint)
                        .accessibilityLabel(Text(String(localized: "content.pinned", table: "Content")))
                }
                if summary.nativeBool("isLocked") == true {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        .accessibilityLabel(Text(String(localized: "content.locked", table: "Content")))
                }
            }
            Text(summary.nativeString("title") ?? "")
                .font(.body.weight(.medium)).lineSpacing(3)
                .foregroundStyle(value.nativeBool("isRead") == true ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.45)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { board(summary); Spacer(minLength: 8); statistics(summary) }
                VStack(alignment: .leading, spacing: 8) { board(summary); HStack(spacing: 16) { statistics(summary) } }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ContentSurface())
        .padding(.bottom, 8).background(ContentSurface(canvas: true))
        .contentShape(Rectangle())
    }
    @ViewBuilder private func board(_ summary: JSONValue) -> some View {
        if let category = summary.nativeString("categoryTitle"), !category.isEmpty {
            Text(category).fontWeight(.medium).foregroundStyle(.tint)
        }
    }
    @ViewBuilder private func statistics(_ summary: JSONValue) -> some View {
        if let comments = summary.nativeInt("commentCount") { Label("\(comments)", systemImage: "bubble.right") }
        if let count = value.nativeInt("newCommentCount"), count > 0 { Text("+\(count)").foregroundStyle(.tint) }
        if let views = summary.nativeInt("viewCount") { Label("\(views)", systemImage: "eye") }
    }
}

struct ContentPageEntry: View {
    @Binding var text: String
    var submit: (Int64) -> Void
    var body: some View {
        HStack {
            TextField(String(localized: "content.page", table: "Content"), text: $text)
                .onSubmit { if let page = Int64(text), page > 0 { submit(page) } }
            Button(String(localized: "content.go", table: "Content")) { if let page = Int64(text), page > 0 { submit(page) } }
                .disabled(Int64(text).map { $0 < 1 || $0 > Int64(Int32.max) } ?? true)
        }
    }
}
