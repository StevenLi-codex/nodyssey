import Foundation

/// A monotonic, consuming two-tap gate. Tab switching itself is never tap one.
struct NativeHomeTabInteraction {
    private var firstTap: TimeInterval?
    private var lastTime: TimeInterval?

    mutating func tap(at uptime: TimeInterval, wasHome: Bool, isHome: Bool, isRoot: Bool, atTop: Bool) -> Bool {
        guard uptime.isFinite, uptime >= 0, lastTime.map({ uptime >= $0 }) ?? true else {
            reset()
            return false
        }
        lastTime = uptime
        guard wasHome, isHome, isRoot else {
            firstTap = nil
            return false
        }
        if let firstTap, uptime <= firstTap + 0.350 {
            self.firstTap = nil // Consume the pair: tap three is a new first tap.
            return true
        }
        firstTap = uptime
        return false
    }

    static func isAtTop(firstMinY: Double?, viewportMinY: Double) -> Bool {
        guard let firstMinY, firstMinY.isFinite, viewportMinY.isFinite else { return false }
        // A half-point rounding allowance, not "first row is visible". Positive
        // overscroll already exposes the earliest cached item, so leave it alone.
        return firstMinY >= viewportMinY - 0.5
    }

    mutating func reset() {
        firstTap = nil
        lastTime = nil
    }
}
