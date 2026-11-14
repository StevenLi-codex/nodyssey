import Testing
import NodysseyNativeCore
@testable import AccountBehavior

@Test func wrongPageCannotReplaceVisiblePage() throws {
    var state = AccountPageState()
    let ticket = state.begin(page: 2)
    #expect(throws: (any Error).self) {
        try state.accept(.object(["page": .integer(1), "hasNextPage": .bool(false), "items": .array([])]), ticket: ticket)
    }
    #expect(state.page == 1 && state.items.isEmpty)
}
@Test func uncertainWriteRequiresReadbackBeforeAnotherConfirmation() {
    var state = AccountMutationState()
    let ticket = state.begin(confirmed: true)!
    state.writeFailed(ticket)
    #expect(state.phase == .uncertain)
    #expect(state.begin(confirmed: true) == nil)
    state.refreshed(ticket)
    #expect(state.begin(confirmed: true) != nil)
}
