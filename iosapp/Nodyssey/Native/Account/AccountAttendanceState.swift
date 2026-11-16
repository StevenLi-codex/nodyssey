import Foundation
import NodysseyNativeCore

/// Transient receipt owned by the mounted My page, never a balance/disk cache.
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
    struct Scope: Equatable {
        let generation: Int
        let identityEpoch: String
        let site: String
        let uid: Int64
    }
    private struct Receipt {
        let value: JSONValue
        let scope: Scope?
        let day: String
    }
    private var receipt: Receipt?

    /// Matches AssetsRepository.toDate/NODESEEK_ZONE, NOT Calendar.current.
    /// The bridge status date is authoritative; this clock only expires old UI
    /// while offline and triggers a read. It never authorizes a sign-in write.
    static func siteDay(_ now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: now)
    }

    mutating func receive(_ value: JSONValue, scope: Scope? = nil, day: String? = nil, now: Date = Date()) {
        guard case .object = value,
              let gain = value["gain"], gain == .null || gain.int != nil,
              let message = value["message"], message == .null || message.string != nil else { return }
        receipt = Receipt(value: value, scope: scope, day: day ?? Self.siteDay(now))
    }
    mutating func reset() { receipt = nil }

    func presentation(status: JSONValue, isSignedIn: Bool, scope: Scope? = nil, now: Date = Date()) -> Presentation {
        guard isSignedIn else { return .guest }
        let date = status["date"]?.string
        let matchingUID = scope == nil || status["uid"]?.int == scope?.uid
        if let receipt, receipt.scope == scope {
            // A newer authoritative server day retires precedence. Older in-flight
            // reads cannot erase today's acknowledgement or supply another gain.
            let newerDay = matchingUID && date.map { $0 > receipt.day } == true
            if !newerDay {
                guard Self.siteDay(now) <= receipt.day else { return .unknown }
                if let gain = receipt.value["gain"]?.int { return .reward(gain) }
                if matchingUID, date == receipt.day, status["hasSignedIn"]?.bool == true,
                   let gain = status["gain"]?.int { return .reward(gain) }
                return .signedWithoutAmount
            }
        }
        guard matchingUID, let date, date >= Self.siteDay(now),
              let signed = status["hasSignedIn"]?.bool else { return .unknown }
        guard signed else { return .unsigned }
        return status["gain"]?.int.map(Presentation.reward) ?? .signedWithoutAmount
    }
}
