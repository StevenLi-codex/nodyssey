import Foundation

/// Geometry shared by the owned container's admission, live slide and release.
/// The start coordinate is bounded to the content, not to a leading-edge strip.
enum ContentBackSwipe {
    static func hasHorizontalContent(contentWidth: Double, boundsWidth: Double,
                                     leftInset: Double, rightInset: Double) -> Bool {
        // Insets may reduce the effective content area, but cannot make a
        // full-width vertical list a horizontal gesture owner.
        let availableWidth = max(boundsWidth, boundsWidth - leftInset - rightInset)
        return contentWidth > availableWidth + 1
    }

    static func begins(velocityX: Double, velocityY: Double, rightToLeft: Bool) -> Bool {
        velocityX.isFinite && velocityY.isFinite && directed(velocityX, rightToLeft) > abs(velocityY) * 1.5
    }

    static func progress(translationX: Double, width: Double, rightToLeft: Bool) -> Double {
        guard translationX.isFinite, width.isFinite, width > 0 else { return 0 }
        return min(1, max(0, directed(translationX, rightToLeft) / width))
    }

    /// UIKit can reset translation when the recognizer leaves its possible state.
    static func initialTranslationCorrection(start: Double, current: Double, reported: Double) -> Double {
        current - start - reported
    }

    static func settleDuration(progress: Double, width: Double, velocity: Double, completing: Bool) -> Double {
        let remaining = width * (completing ? 1 - progress : progress)
        let speed = max(750, min(2_400, completing ? velocity : -velocity))
        return min(0.32, max(0.12, remaining / speed))
    }

    private static func directed(_ value: Double, _ rightToLeft: Bool) -> Double { rightToLeft ? -value : value }

    static func shouldReturn(startX: Double, width: Double, translationX: Double,
                             translationY: Double, predictedX: Double,
                             rightToLeft: Bool = false) -> Bool {
        guard [startX, width, translationX, translationY, predictedX].allSatisfy(\.isFinite),
              width > 0, startX >= 0, startX <= width else { return false }
        let travel = directed(translationX, rightToLeft)
        let projected = directed(predictedX, rightToLeft)
        guard projected >= travel, begins(velocityX: translationX, velocityY: translationY, rightToLeft: rightToLeft) else { return false }
        let threshold = max(64, min(110, width * 0.22))
        let fastSwipe = travel >= 44 && projected >= max(140, width * 0.4) &&
            projected - travel >= 60
        return travel >= threshold || fastSwipe
    }
}
