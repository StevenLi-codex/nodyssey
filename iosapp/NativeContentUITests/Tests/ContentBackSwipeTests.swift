import Foundation
import Testing
@testable import NativeContentState

@Suite struct ContentBackSwipeTests {
    @Test func deliberateLeadingEdgeSwipeRequestsReturn() {
        #expect(ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 240, translationY: 12, predictedX: 280))
        #expect(ContentBackSwipe.shouldReturn(startX: 392, width: 400,
            translationX: -240, translationY: 12, predictedX: -280, rightToLeft: true))
    }

    @Test func fastSwipeWithShortTravelRequestsReturn() {
        #expect(ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 60, translationY: 0, predictedX: 240))
        // The former 90pt/300pt projection case is also intentionally accepted.
        #expect(ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 90, translationY: 0, predictedX: 300))
    }

    @Test func moderateSlowSwipeRequestsReturn() {
        #expect(ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 100, translationY: 0, predictedX: 100))
    }

    @Test func leadingEdgeStartWithinThirtyTwoPointsRequestsReturn() {
        #expect(ContentBackSwipe.shouldReturn(startX: 32, width: 400,
            translationX: 100, translationY: 0, predictedX: 100))
    }

    @Test func sensitivityBoundariesPreserveAccidentalDragRejection() {
        #expect(ContentBackSwipe.shouldReturn(startX: 36, width: 400,
            translationX: 44, translationY: 0, predictedX: 160))
        #expect(ContentBackSwipe.shouldReturn(startX: 37, width: 400,
            translationX: 240, translationY: 0, predictedX: 280))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 60, translationY: 0, predictedX: 159))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 60, translationY: 40, predictedX: 240))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 60, translationY: -80, predictedX: 240))
    }

    @Test func slowSwipeThresholdScalesWithClampedViewportWidth() {
        for (width, threshold) in [(200.0, 64.0), (400.0, 88.0), (1_000.0, 110.0)] {
            #expect(ContentBackSwipe.shouldReturn(startX: 8, width: width,
                translationX: threshold, translationY: 0, predictedX: threshold))
            #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: width,
                translationX: threshold - 1, translationY: 0, predictedX: threshold - 1))
        }
    }

    @Test func sensitiveSwipeAndContentBoundariesMirrorInRightToLeftLayout() {
        #expect(ContentBackSwipe.shouldReturn(startX: 368, width: 400,
            translationX: -60, translationY: 0, predictedX: -240, rightToLeft: true))
        #expect(ContentBackSwipe.shouldReturn(startX: 364, width: 400,
            translationX: -100, translationY: 0, predictedX: -100, rightToLeft: true))
        #expect(ContentBackSwipe.shouldReturn(startX: 200, width: 400,
            translationX: -240, translationY: 0, predictedX: -280, rightToLeft: true))
        #expect(!ContentBackSwipe.shouldReturn(startX: 392, width: 400,
            translationX: -43, translationY: 0, predictedX: -300, rightToLeft: true))
        #expect(!ContentBackSwipe.shouldReturn(startX: 392, width: 400,
            translationX: -60, translationY: 40, predictedX: -240, rightToLeft: true))
    }

    @Test func centerIsEligibleButVerticalAndShortDragsAreNot() {
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 20, translationY: 300, predictedX: 30))
        #expect(ContentBackSwipe.shouldReturn(startX: 160, width: 400,
            translationX: 240, translationY: 12, predictedX: 280))
        // Product intent: sub-44pt motion remains a rejected accidental tap/jitter.
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 43, translationY: 0, predictedX: 300))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 200, translationY: 180, predictedX: 280))
    }

    @Test func reversingOrWrongDirectionDoesNotTurnACancelIntoReturn() {
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 240, translationY: 0, predictedX: 100))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: -240, translationY: 0, predictedX: -280))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 240, translationY: 0, predictedX: 280, rightToLeft: true))
    }

    @Test func reversingAboveDistanceThresholdDoesNotRequestReturn() {
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 300, translationY: 0, predictedX: 220))
        #expect(!ContentBackSwipe.shouldReturn(startX: 392, width: 400,
            translationX: -300, translationY: 0, predictedX: -220, rightToLeft: true))
    }

    @Test func progressTracksTravelBothWaysAndClampsOvershoot() {
        #expect(ContentBackSwipe.begins(velocityX: -100, velocityY: 12, rightToLeft: true))
        #expect(!ContentBackSwipe.begins(velocityX: 100, velocityY: 12, rightToLeft: true))
        #expect(!ContentBackSwipe.begins(velocityX: 100, velocityY: 90, rightToLeft: false))
        #expect(ContentBackSwipe.progress(translationX: 100, width: 400, rightToLeft: false) == 0.25)
        #expect(ContentBackSwipe.progress(translationX: -240, width: 400, rightToLeft: true) == 0.6)
        #expect(ContentBackSwipe.progress(translationX: -120, width: 400, rightToLeft: true) == 0.3)
        #expect(ContentBackSwipe.progress(translationX: -440, width: 400, rightToLeft: true) == 1)
        #expect(ContentBackSwipe.progress(translationX: 10, width: 400, rightToLeft: true) == 0)
    }

    @Test func invalidGeometryFailsClosed() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(!ContentBackSwipe.shouldReturn(startX: invalid, width: 400,
                translationX: 240, translationY: 0, predictedX: 280))
            #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: invalid,
                translationX: 240, translationY: 0, predictedX: 280))
            #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
                translationX: invalid, translationY: 0, predictedX: 280))
            #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
                translationX: 240, translationY: invalid, predictedX: 280))
            #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
                translationX: 240, translationY: 0, predictedX: invalid))
        }
        #expect(!ContentBackSwipe.shouldReturn(startX: -1, width: 400,
            translationX: 240, translationY: 0, predictedX: 280))
        #expect(!ContentBackSwipe.shouldReturn(startX: 401, width: 400,
            translationX: 240, translationY: 0, predictedX: 280))
        #expect(!ContentBackSwipe.shouldReturn(startX: 0, width: 0,
            translationX: 240, translationY: 0, predictedX: 280))
    }
}
