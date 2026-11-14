import SwiftUI
import NodysseyNativeCore

struct ContentShareLink: View {
    @EnvironmentObject private var app: NativeAppModel
    let postID: Int64
    let page: Int64
    var floor: String? = nil
    @StateObject private var site = NativeStore()
    @State private var retry = 0
    private var url: URL? {
        guard let current = site.value.nativeString("current"),
              let origin = site.value.nativeArray("sites").first(where: { $0.nativeString("id") == current })?.nativeString("origin"),
              var components = URLComponents(string: origin), components.scheme == "https", components.host != nil else { return nil }
        components.path = "/post-\(postID)-\(max(1, page))"
        components.query = nil
        components.fragment = floor.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
        return components.url
    }
    var body: some View {
        Group {
            if let url { ShareLink(item: url) }
            else if let failure = site.failure { NativeFailureView(failure: failure, retry: { retry += 1 }) }
            else { ProgressView() }
        }
        .task(id: "\(app.generation)|\(retry)") { await site.load(app, "site.get") }
    }
}
