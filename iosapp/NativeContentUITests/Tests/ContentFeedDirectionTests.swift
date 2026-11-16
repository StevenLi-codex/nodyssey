import Foundation
import Testing
@testable import NativeContentState

// Reproduces the old geometry-driven rail reversing on tiny movements.
@Test func feedRailDoesNotCollapseOnSubthresholdMotion() {
    var direction = ContentFeedDirection()
    direction.record(translation: 0)
    direction.record(translation: -12)
    #expect(direction.expanded)
    direction.record(translation: -24)
    #expect(direction.expanded)
    direction.record(translation: -39)
    #expect(direction.expanded)
    direction.record(translation: -40)
    #expect(!direction.expanded)
}

@Test func feedRailReversalMustEarnItsOwnThreshold() {
    var direction = ContentFeedDirection()
    direction.record(translation: -40)
    #expect(!direction.expanded)
    direction.record(translation: -10) // 30 down: not enough to expand.
    #expect(!direction.expanded)
    direction.record(translation: -20) // Reversal resets the pending 30.
    direction.record(translation: 19)
    #expect(!direction.expanded)
    direction.record(translation: 20)
    #expect(direction.expanded)
}

@Test func feedRailGestureEndAndCancellationKeepStateButDiscardPartialTravel() {
    var direction = ContentFeedDirection()
    direction.record(translation: -30)
    direction.endGesture()
    direction.record(translation: -20)
    #expect(direction.expanded, "Separate short drags must not combine into a collapse")
    direction.record(translation: -40)
    #expect(!direction.expanded)
    direction.endGesture()
    direction.record(translation: 39)
    #expect(!direction.expanded)
    direction.endGesture()
    direction.record(translation: 1)
    #expect(!direction.expanded)
    direction.record(translation: 40)
    #expect(direction.expanded, "The rail must not remain latched after cancellation")
}

@Test func feedRailIgnoresRepeatedAndNonfiniteInput() {
    var direction = ContentFeedDirection()
    direction.record(translation: -40)
    for _ in 0..<100 { direction.record(translation: -40) }
    direction.record(translation: .nan)
    direction.record(translation: .infinity)
    #expect(!direction.expanded)
    direction.record(translation: 0)
    #expect(direction.expanded)
}
