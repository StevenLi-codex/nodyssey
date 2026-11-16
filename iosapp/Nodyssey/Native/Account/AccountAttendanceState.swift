import Foundation
import NodysseyNativeCore

/// My-page receipt projection. Both inputs are existing NativeAccount DTOs, never
/// a balance delta or an amount inferred from FIXED_FIVE. The repository resolves
/// startup status from today's own attendance ledger (scoped to UID/site date).
struct AccountAttendanceState {
    enum Presentation: Equatable {
        case guest, unknown, unsigned, reward(Int64), signedWithoutAmount
        var isDone: Bool {
            switch self {
            case .reward, .signedWithoutAmount: return true
            default: return false
            }
        }
    }
    private var receipt: JSONValue?

    mutating func receive(_ value: JSONValue) {
        // The mapper always emits gain and message (including explicit null).
        // Do not turn a malformed/empty transport payload into a signed receipt.
        guard case .object = value,
              let gain = value["gain"], gain == .null || gain.int != nil,
              let message = value["message"], message == .null || message.string != nil else { return }
        receipt = value
    }
    mutating func reset() { receipt = nil }

    func presentation(status: JSONValue, isSignedIn: Bool) -> Presentation {
        guard isSignedIn else { return .guest }
        if let receipt {
            if let gain = receipt["gain"]?.int { return .reward(gain) }
            // The original repository may resolve a message-only response via
            // today's ledger. This is an attendance receipt, not total balance.
            if status["hasSignedIn"]?.bool == true, let gain = status["gain"]?.int { return .reward(gain) }
            return .signedWithoutAmount
        }
        guard let signed = status["hasSignedIn"]?.bool else { return .unknown }
        guard signed else { return .unsigned }
        return status["gain"]?.int.map(Presentation.reward) ?? .signedWithoutAmount
    }
}
