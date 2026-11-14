import Testing
@testable import AccountBehavior

@Test func acknowledgementThenFailedReadbackNeverBecomesFailedWriteOrRetry() {
    var state = AccountMutationState()
    #expect(state.begin(confirmed: false) == nil)
    let ticket = state.begin(confirmed: true)!
    #expect(state.begin(confirmed: true) == nil)
    state.acknowledge(ticket)
    state.readFailed(ticket)
    #expect(state.phase == .savedNeedsRefresh)
    #expect(state.begin(confirmed: true) == nil)
    state.refreshed(ticket)
    #expect(state.phase == .verified)
    #expect(state.begin(confirmed: true) != nil)
}
@Test func unknownPasswordOutcomeCannotBeProvedBySuccessfulStatusRead() {
    var state = AccountMutationState()
    let ticket = state.begin(confirmed: true, readbackCanResolveUncertainty: false)!
    state.writeFailed(ticket)
    state.refreshed(ticket)
    #expect(state.phase == .uncertain)
    #expect(state.blocksWrite)
}

@Test func sessionReplacementRejectsOldMutationCompletion() {
    var state = AccountMutationState()
    let ticket = state.begin(confirmed: true)!
    state.invalidate()
    state.acknowledge(ticket)
    state.refreshed(ticket)
    #expect(state.phase == .idle)
}
