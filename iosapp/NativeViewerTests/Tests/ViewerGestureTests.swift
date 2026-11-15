import Foundation
import CoreGraphics

@main
struct ViewerGestureTests {
    static func main() {
        // A zoomed pan, horizontal page turn, edge-back swipe or pinch must never dismiss.
        assert(NativeImageGesturePolicy.canBeginDismiss(scale: 1, minimum: 1, velocity: CGPoint(x: 10, y: -80), locationX: 160, width: 320, touches: 1))
        assert(!NativeImageGesturePolicy.canBeginDismiss(scale: 2, minimum: 1, velocity: CGPoint(x: 0, y: 80), locationX: 160, width: 320, touches: 1))
        assert(!NativeImageGesturePolicy.canBeginDismiss(scale: 1, minimum: 1, velocity: CGPoint(x: 80, y: 10), locationX: 160, width: 320, touches: 1))
        assert(!NativeImageGesturePolicy.canBeginDismiss(scale: 1, minimum: 1, velocity: CGPoint(x: 10, y: 80), locationX: 8, width: 320, touches: 1))
        assert(!NativeImageGesturePolicy.canBeginDismiss(scale: 1, minimum: 1, velocity: CGPoint(x: 10, y: 80), locationX: 312, width: 320, touches: 1))
        assert(!NativeImageGesturePolicy.canBeginDismiss(scale: 1, minimum: 1, velocity: CGPoint(x: 10, y: 80), locationX: 160, width: 320, touches: 2))
        print("PASS: dismiss admission excludes zoom, paging, system edges and pinch")
        assert(!NativeImageGesturePolicy.shouldDismiss(translationY: 120, scale: 1, minimum: 1))
        assert(NativeImageGesturePolicy.shouldDismiss(translationY: -121, scale: 1, minimum: 1))
        assert(!NativeImageGesturePolicy.shouldDismiss(translationY: 200, scale: 2, minimum: 1))
        print("PASS: release threshold is bidirectional and rechecks zoom")
        let rect = NativeImageGesturePolicy.zoomRect(tap: CGPoint(x: 240, y: 360), viewport: CGSize(width: 320, height: 640), scale: 2.5)
        assert(rect.midX == 240 && rect.midY == 360)
        assert(abs(rect.width * 2.5 - 320) < 0.001 && abs(rect.height * 2.5 - 640) < 0.001)
        print("PASS: zoom rectangle centers on the actual tap rather than the image center")
    }
}
