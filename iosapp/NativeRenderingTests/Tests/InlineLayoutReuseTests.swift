import Foundation
import CoreGraphics
import Testing
@testable import NativeRendering

@Test func inlineArrangementReusesMeasurementsAndInvalidatesEveryInput() {
    var cache = NativeInlineArrangementCache<Int>()
    var measurements = 0
    var currentSize = CGSize(width: 20, height: 10)
    func measure(_ index: Int, _ width: CGFloat) -> NativeInlineMeasurement {
        measurements += 1
        return NativeInlineMeasurement(size: currentSize, isLineBreak: index == 1)
    }
    let first = cache.arrangement(width: 100, revision: 0, count: 3, measure: measure)
    let placed = cache.arrangement(width: 100, revision: 0, count: 3, measure: measure)
    #expect(first.frames == placed.frames)
    #expect(measurements == 3) // size + placement must not measure six times.
    _ = cache.arrangement(width: 80, revision: 0, count: 3, measure: measure)
    #expect(measurements == 6)
    currentSize = CGSize(width: 30, height: 25)
    let edited = cache.arrangement(width: 80, revision: 1, count: 3, measure: measure)
    #expect(measurements == 9)
    #expect(edited.frames[0].size == currentSize)
    // SwiftUI updateCache is the subview/environment invalidation boundary, even
    // when the content/revision and number of subviews remain the same.
    cache.invalidate()
    currentSize = CGSize(width: 35, height: 30)
    let updated = cache.arrangement(width: 80, revision: 1, count: 3, measure: measure)
    #expect(measurements == 12)
    #expect(updated.frames[0].size == currentSize)
    _ = cache.arrangement(width: 80, revision: 1, count: 2, measure: measure)
    #expect(measurements == 14)
    _ = cache.arrangement(width: nil, revision: 1, count: 2, measure: measure)
    #expect(measurements == 16)
    _ = cache.arrangement(width: 320, revision: 1, count: 2, measure: measure)
    #expect(measurements == 18) // natural vs constrained width are distinct proposals.
}
