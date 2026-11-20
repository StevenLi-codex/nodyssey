import Combine
import Foundation
import Testing
@testable import NativeContentState

@MainActor
@Test func feedDragOnlyPublishesChangesToTheVisibleRail() {
    let drag = ContentFeedDragState()
    var changes: [Bool] = []
    let subscription = drag.$expanded.dropFirst().sink { changes.append($0) }

    for step in 1...39 { drag.record(translation: -CGFloat(step)) }
    #expect(drag.expanded)
    #expect(changes.isEmpty, "Finger samples below the rail threshold must not invalidate its list owner")

    drag.record(translation: -40)
    for step in 41...160 { drag.record(translation: -CGFloat(step)) }
    drag.record(translation: .nan)
    drag.record(translation: .infinity)
    #expect(!drag.expanded)
    #expect(changes == [false], "Further travel while already collapsed must stay private")

    drag.endGesture()
    drag.record(translation: 39)
    drag.endGesture() // Cancellation discards partial travel without publishing.
    drag.record(translation: 1)
    #expect(!drag.expanded)
    #expect(changes == [false])
    drag.record(translation: 40)
    #expect(drag.expanded)
    #expect(changes == [false, true])

    drag.reset()
    #expect(changes == [false, true], "An already-expanded reset must not invalidate its owner")
    drag.record(translation: -40)
    drag.reset()
    drag.reset()
    #expect(drag.expanded)
    #expect(changes == [false, true, false, true])
    withExtendedLifetime(subscription) {}
}
