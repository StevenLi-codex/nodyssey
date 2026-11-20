import Foundation

/// Completion-only fallback for the thread's existing simultaneous drag observer.
/// Native interactive navigation remains primary; never replace its recognizer or
/// delegate. A short, vertical, interior, reversed or cancelled drag must not pop.
enum ContentBackSwipe {
    static func shouldReturn(startX: Double, width: Double, translationX: Double,
                             translationY: Double, predictedX: Double,
                             rightToLeft: Bool = false) -> Bool {
        guard [startX, width, translationX, translationY, predictedX].allSatisfy(\.isFinite),
              width > 0, startX >= 0, startX <= width else { return false }
        let leadingDistance = rightToLeft ? width - startX : startX
        let direction = rightToLeft ? -1.0 : 1.0
        let travel = translationX * direction
        let projected = predictedX * direction
        guard leadingDistance <= 36, projected >= travel,
              travel > abs(translationY) * 1.5 else { return false }
        let threshold = max(64, min(110, width * 0.22))
        let fastSwipe = travel >= 44 && projected >= max(140, width * 0.4) &&
            projected - travel >= 60
        return travel >= threshold || fastSwipe
    }
}
