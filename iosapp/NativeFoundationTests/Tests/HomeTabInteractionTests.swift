import Foundation
import Testing
@testable import NativeFoundation

@Test func homeSwitchIsNotFirstTapAndLeavingCancelsPair() {
    var gate = NativeHomeTabInteraction()
    #expect(!{ gate.tap(at: 1, wasHome: false, isHome: true, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 1.1, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 1.2, wasHome: true, isHome: false, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 1.3, wasHome: false, isHome: true, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 1.4, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect({ gate.tap(at: 1.5, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
}

@Test func homeDoubleTapUsesInclusive350msAndConsumesPair() {
    var gate = NativeHomeTabInteraction()
    #expect(!{ gate.tap(at: 1, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect({ gate.tap(at: 1.350, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 1.4, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect({ gate.tap(at: 1.5, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    gate.reset()
    #expect(!{ gate.tap(at: 2, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect(!{ gate.tap(at: 2.350001, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    #expect({ gate.tap(at: 2.4, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
}

@Test func detailTopAndInvalidTimeCannotCompletePair() {
    for blocked in [0, 1, 2, 3, 4, 5] {
        var gate = NativeHomeTabInteraction()
        #expect(!{ gate.tap(at: 1, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
        let time: Double = blocked == 2 ? .nan : blocked == 3 ? .infinity : blocked == 4 ? 0.9 : blocked == 5 ? -1 : 1.1
        #expect(!{ gate.tap(at: time, wasHome: true, isHome: true, isRoot: blocked != 0, atTop: blocked == 1) }())
        #expect(!{ gate.tap(at: 1.2, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
        #expect({ gate.tap(at: 1.3, wasHome: true, isHome: true, isRoot: true, atTop: false) }())
    }
}

@Test func visibleFirstRowIsNotNecessarilyAtTop() {
    #expect(NativeHomeTabInteraction.isAtTop(firstMinY: 100, viewportMinY: 100))
    #expect(NativeHomeTabInteraction.isAtTop(firstMinY: 110, viewportMinY: 100))
    #expect(!NativeHomeTabInteraction.isAtTop(firstMinY: 80, viewportMinY: 100))
    #expect(!NativeHomeTabInteraction.isAtTop(firstMinY: nil, viewportMinY: 100))
    #expect(!NativeHomeTabInteraction.isAtTop(firstMinY: .nan, viewportMinY: 100))
    #expect(!NativeHomeTabInteraction.isAtTop(firstMinY: 100, viewportMinY: .infinity))
}
