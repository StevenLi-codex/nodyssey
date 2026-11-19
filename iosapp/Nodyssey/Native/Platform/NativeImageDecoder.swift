import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// ImageIO decoding stays on the worker. SVG rasterization remains in Kotlin's existing pipeline.
enum NativeImageDecoder {
    static func aspectRatio(_ data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGFloat(height) / CGFloat(width) : CGFloat(width) / CGFloat(height)
    }

    static func decode(_ data: Data, maxPixel: Int? = nil) -> UIImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count != 1 else {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let target = max(1, min(maxPixel ?? max(width, height), max(width, height)))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: thumbnail)
        }
        guard count > 1, count <= 300 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        var pixels = 0
        for index in 0..<count {
            if Task.isCancelled { return nil }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { return UIImage(data: data) }
            pixels += width * height
            // Bound animation decode memory, not just the encoded file's size.
            guard pixels <= 16_000_000,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { return UIImage(data: data) }
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            let ticks = min(100, max(1, Int((max(0.02, min(delay, 2)) / 0.02).rounded())))
            let frame = UIImage(cgImage: cgImage)
            frames.append(contentsOf: repeatElement(frame, count: ticks))
            duration += Double(ticks) * 0.02
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
