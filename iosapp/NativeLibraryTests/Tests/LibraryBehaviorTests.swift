import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@Test func filteredSelectionDoesNotLoseHiddenIDs() throws {
    var library = LibrarySelection()
    library.selected = [9_007_199_254_740_993]
    library.selectVisible([7, 8])
    #expect(library.selected == [9_007_199_254_740_993, 7, 8])
    library.completeRemoval(succeeded: [7], failed: [8])
    #expect(library.selected == [9_007_199_254_740_993, 8])
    #expect(library.undoIDs == [7])
}

@Test func togglingAllVisibleClearsOnlyVisibleSelection() {
    var library = LibrarySelection()
    library.selected = [1, 2, 3]
    library.selectVisible([1, 2])
    #expect(library.selected == [3])
}
