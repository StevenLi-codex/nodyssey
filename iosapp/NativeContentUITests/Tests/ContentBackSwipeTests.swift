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

    @Test func normalReadingInteriorAndShortDragsNeverRequestReturn() {
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 20, translationY: 300, predictedX: 30))
        #expect(!ContentBackSwipe.shouldReturn(startX: 160, width: 400,
            translationX: 240, translationY: 12, predictedX: 280))
        #expect(!ContentBackSwipe.shouldReturn(startX: 8, width: 400,
            translationX: 90, translationY: 0, predictedX: 300))
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
