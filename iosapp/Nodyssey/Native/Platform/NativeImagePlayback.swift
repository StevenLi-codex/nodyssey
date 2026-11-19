import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor enum NativeImagePlayback {
    static func update(_ view: UIImageView, image: UIImage, reduceMotion: Bool) {
        if reduceMotion {
            // Stopping alone is insufficient for UIImage's internally animated image.
            // Replace it with a real still frame, including when the setting changes live.
            view.stopAnimating()
            let still = image.images?.first ?? image
            if view.image !== still { view.image = still }
        } else {
            if view.image !== image { view.image = image }
            if image.images != nil, !view.isAnimating { view.startAnimating() }
        }
    }
}
