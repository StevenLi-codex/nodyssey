import Testing
@testable import AccountBehavior

@Test func cancelledChallengeCannotResurrectOrKeepSecrets() {
    var state = AccountAuthState()
    state.account = "reader"; state.password = "transient-only"; state.token = "challenge-token"
    let ticket = state.begin()!
    #expect(state.begin() == nil)
    state.cancel()
    let accepted = state.acceptChallenge("late", ticket: ticket)
    #expect(!accepted)
    #expect(state.password.isEmpty && state.token.isEmpty && state.code.isEmpty)
    #expect(state.challenge == nil)
}
@Test func challengeConsumesPasswordAndRejectsNonASCIICode() {
    var state = AccountAuthState()
    state.account = "reader"; state.password = "pw"; state.token = "t"
    let ticket = state.begin()!
    let accepted = state.acceptChallenge("opaque-handle", ticket: ticket)
    #expect(accepted)
    #expect(state.password.isEmpty && state.token.isEmpty)
    state.code = "１２３４５６"
    #expect(!state.canSubmit)
    state.code = "123456"
    #expect(state.canSubmit)
    state.cancel()
    #expect(!state.canSubmit)
}
