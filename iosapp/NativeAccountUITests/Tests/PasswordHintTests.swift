import Testing
@testable import AccountBehavior

@Test func passwordHintMatchesSharedLengthAndVarietyWithoutChangingGate() {
    #expect(AccountInputState.passwordStrength("") == nil)
    #expect(AccountInputState.passwordStrength("aB1!") == "fair")
    #expect(AccountInputState.passwordStrength("abcdefgh") == "weak")
    #expect(AccountInputState.passwordStrength("abcdefghijkl") == "fair")
    #expect(AccountInputState.passwordStrength("abcdefghijklmnopqrstuvwxy") == "strong")
    #expect(AccountInputState.passwordStrength("Abcdefghijk1!2345") == "best")
    #expect(AccountInputState.passwordStrength("                ") == "fair")
    #expect(AccountInputState.passwordStrength("éÉ١!éÉ١!éÉ١!éÉ١!") == "best")
    #expect(AccountInputState.validPassword(current: "old", new: "abcdefgh", confirmation: "abcdefgh"))
}
