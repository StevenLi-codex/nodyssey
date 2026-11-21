import SwiftUI
import NodysseyNativeCore

// Unrelated destinations and Kotlin I/O boundaries only. No gallery/viewer stand-in.
struct NativeScreen: View {
    let destination: NativeDestination
    var body: some View {
        if destination.route == "ImageViewer" {
            ProbeMediaRoute.make(destination: destination) ?? AnyView(Text("Invalid route fixture"))
        } else if destination.route == "PostDetail" {
            NativeRemoteImage(url: Actions.cover)
        } else {
            Text(destination.route)
        }
    }
}
struct NativeFailureView: View { let failure: NativeFailure; var retry: (() -> Void)?; var body: some View { Text("Failure") } }
struct NativeExternalBrowser: View { let url: URL; var body: some View { EmptyView().onAppear { fatalError("unexpected browser") } } }
struct NativeCodeBlock: View { let code: NativeCode; let actions: NativeRichTextActions; var body: some View { EmptyView().onAppear { fatalError("unexpected code") } } }

@MainActor final class NativeImageState: ObservableObject {
    @Published private(set) var image: UIImage?
    var url: String?, scope: NativeImageScope?
    var data: Data? { nil }
    var aspectRatio: CGFloat? { 1 }
    var failure: Bool { false }
    var deferredForWifi: Bool { false }
    func load(_ url: String, allowMetered: Bool = false, scope: NativeImageScope? = nil, maxPixel: Int? = nil) {
        guard self.url != url || self.scope != scope || image == nil else { return }
        self.url = url
        self.scope = scope
        image = UIImage(systemName: "photo")!
    }
    func cancel() {}
}
