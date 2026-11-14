import Foundation

/// Memory-only form. Epoch tickets reject callbacks after cancel/session replacement.
struct AccountAuthState {
    var account = ""
    var password = ""
    var token = ""
    var code = ""
    private(set) var challenge: String?
    private(set) var busy = false
    private var epoch = UUID()

    var canSubmit: Bool {
        guard !busy else { return false }
        if challenge != nil { return code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) } }
        return !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty && !token.isEmpty
    }
    mutating func begin() -> UUID? {
        guard canSubmit else { return nil }
        busy = true
        epoch = UUID()
        return epoch
    }
    func accepts(_ ticket: UUID) -> Bool { busy && ticket == epoch }
    @discardableResult mutating func acceptChallenge(_ value: String, ticket: UUID) -> Bool {
        guard accepts(ticket), !value.isEmpty else { return false }
        password = ""; token = ""; code = ""; challenge = value; busy = false
        return true
    }
    mutating func failed(_ ticket: UUID) {
        guard accepts(ticket) else { return }
        busy = false; token = ""; code = ""
    }
    mutating func cancel() {
        epoch = UUID(); busy = false; password = ""; token = ""; code = ""; challenge = nil
    }
}
