import SwiftUI
import UIKit
// Transport/image-state boundary: deterministic already-loaded raster; no network, graph or cache.
typealias NativeImageScope = Int
@MainActor final class NativeAppModel: ObservableObject { var nativeImageScope: Int { 1 } }
@MainActor final class NativeImageState: ObservableObject {
 @Published var image: UIImage? = UIImage(systemName: "photo")
 var url = "https://example.invalid/a.png"; var scope = 1
 var aspectRatio: CGFloat? = 1; var failure = false; var deferredForWifi = false
 func load(_ url: String, allowMetered: Bool = false, scope: Int, maxPixel: Int? = nil) { self.url=url; self.scope=scope }
 func cancel() {}
}
enum NativeImagePlayback { static func update(_ view: UIImageView, image: UIImage, reduceMotion: Bool) { view.image=image } }
// Viewer destination boundary: records direct local presentation; not the production viewer.
struct NativeImageViewer: View { let url: String; var body: some View { Text("viewer").onAppear { Probe.localOpen += 1 } } }
struct NativeCodeBlock: View { let code: NativeCode; let actions: NativeRichTextActions; var body: some View { Text(code.code) } }

