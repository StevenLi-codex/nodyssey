// Explicitly synthetic UIKit/Kotlin boundary; no network, cookies, disk cache or live admission.
// ImageIO/CoreGraphics and all staged state/cache/scheduling implementations are real shipping code.
import Foundation
import CoreGraphics
import ImageIO

final class UIImage: @unchecked Sendable {
    let cgImage: CGImage?
    let images: [UIImage]?
    let duration: TimeInterval
    var size: CGSize { cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? images?.first?.size ?? .zero }
    init(cgImage: CGImage) { self.cgImage = cgImage; images = nil; duration = 0 }
    private init(images: [UIImage], duration: TimeInterval) { cgImage = nil; self.images = images; self.duration = duration }
    convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(cgImage: image)
    }
    static func animatedImage(with images: [UIImage], duration: TimeInterval) -> UIImage? {
        UIImage(images: images, duration: duration)
    }
}
final class UIImageView {
    var image: UIImage?
    var isAnimating = false
    func stopAnimating() { isAnimating = false }
    func startAnimating() { isAnimating = true }
}

final class NativeRequest {
    var cancelled = false
    func cancel() { cancelled = true }
}
@MainActor final class NativePlatform {
    static let shared = NativePlatform()
    struct Call {
        let url: String
        let allowMetered: Bool
        let completion: (NSData?, String?) -> Void
        let request: NativeRequest
    }
    var calls: [Call] = []
    func image(url: String, allowMetered: Bool, completion: @escaping (NSData?, String?) -> Void) -> NativeRequest {
        let request = NativeRequest()
        calls.append(Call(url: url, allowMetered: allowMetered, completion: completion, request: request))
        return request
    }
    func reset() { calls = [] }
}
