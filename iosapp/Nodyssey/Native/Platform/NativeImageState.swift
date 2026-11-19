import Foundation
import Combine
#if canImport(UIKit)
import UIKit
import NodysseyShell
#endif

struct NativeImageScope: Hashable, Sendable {
    let appIdentity: ObjectIdentifier
    let identityEpoch: String?
    let boundaryEpoch: String?
    let boundaryPhase: String?
    let generation: Int
    let site: String?
    let siteOrigin: String?
    let wifiOnly: Bool?
}

@MainActor
final class NativeImageState: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var data: Data?
    @Published private(set) var failure = false
    @Published private(set) var deferredForWifi = false
    @Published private(set) var aspectRatio: CGFloat?
    private var request: NativeRequest?
    private var decodeTask: Task<Void, Never>?
    private var identity = UUID()
    private(set) var url: String?
    private(set) var scope: NativeImageScope?
    private var maxPixel: Int?

    func load(_ url: String, allowMetered: Bool = false, scope: NativeImageScope? = nil, maxPixel: Int? = nil) {
        // An accepted image belongs to this presentation owner, not a new cache access.
        if self.url == url, self.scope == scope, self.maxPixel == maxPixel,
           image != nil || request != nil || decodeTask != nil { return }
        cancel()
        NativeImagePipeline.shared.admitScope(scope)
        self.maxPixel = maxPixel
        self.scope = scope
        self.url = url
        image = nil
        data = nil
        aspectRatio = nil
        failure = false
        deferredForWifi = false
        let identity = self.identity
        request = NativePlatform.shared.image(url: url, allowMetered: allowMetered) { [weak self] bytes, error in
            guard let self, self.identity == identity, self.url == url else { return }
            self.request = nil
            guard error == nil, let bytes else {
                self.failure = true
                self.deferredForWifi = error == "IMAGE_WIFI_ONLY"
                return
            }
            let data = bytes as Data
            self.decodeTask = Task { [weak self] in
                let image = await NativeImagePipeline.shared.image(data, scope: scope, maxPixel: maxPixel)
                let ratio = await Task.detached(priority: .userInitiated) { NativeImageDecoder.aspectRatio(data) }.value
                guard !Task.isCancelled, let self, self.identity == identity, self.url == url else { return }
                self.decodeTask = nil
                self.aspectRatio = ratio
                self.data = data
                self.image = image
                self.failure = image == nil
            }
        }
    }
    func cancel() {
        identity = UUID()
        request?.cancel()
        request = nil
        decodeTask?.cancel()
        decodeTask = nil
    }
    deinit { request?.cancel(); decodeTask?.cancel() }
}
