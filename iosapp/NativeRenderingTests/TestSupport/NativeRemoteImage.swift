import SwiftUI

// Test boundary only. Code-only composition fixtures must never load a platform image.
// Unlike the signature fixture, accidental image use fails rather than faking success.
struct NativeRemoteImage: View {
    let url: String
    var aspectFit: Bool = true
    var onOpen: (() -> Void)? = nil; var body: Never { fatalError("Image rendering is outside code-slot composition tests") }
}
