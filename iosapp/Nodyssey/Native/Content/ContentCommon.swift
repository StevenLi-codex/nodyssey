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

struct ContentAvatar: View {
    let value: JSONValue
    var body: some View {
        if let url = value.nativeString("avatarUrl") {
            NativeRemoteImage(url: url, aspectFit: true).frame(width: 36, height: 36).clipShape(Circle())
        }
    }
}

struct ContentPostRow: View {
    @EnvironmentObject private var app: NativeAppModel
    let value: JSONValue
    var body: some View {
        let summary = value["summary"] ?? value
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                ContentAvatar(value: summary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.nativeString("title") ?? "").font(.headline)
                        .foregroundStyle(value.nativeBool("isRead") == true ? .secondary : .primary)
                    Text(summary.nativeString("authorName") ?? "").font(.subheadline)
                }
                Spacer()
                if summary.nativeBool("isPinned") == true { Image(systemName: "pin.fill").accessibilityLabel(Text(String(localized: "content.pinned", table: "Content"))) }
                if summary.nativeBool("isLocked") == true { Image(systemName: "lock.fill").accessibilityLabel(Text(String(localized: "content.locked", table: "Content"))) }
            }
            HStack {
                if let category = summary.nativeString("categoryTitle") { Text(category) }
                if let comments = summary.nativeInt("commentCount") { Label("\(comments)", systemImage: "bubble.right") }
                if let views = summary.nativeInt("viewCount") { Label("\(views)", systemImage: "eye") }
                if let count = value.nativeInt("newCommentCount"), count > 0 { Text("+\(count)").foregroundStyle(.tint) }
                Spacer()
                if let time = summary.nativeString("lastActiveText") { Text(time) }
            }.font(.caption).foregroundStyle(.secondary)
        }
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
