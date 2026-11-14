import Foundation
import NodysseyNativeCore

/// Never display NSError/server detail, request bodies or arbitrary bridge messages.
func nativeSafeFailure(_ error: Error) -> NativeFailure {
    NativeFailure(code: (error as? NativeFailure)?.code ?? "TRANSPORT", message: "Operation could not be completed")
}

enum NativeRecovery { case signIn, challenge, retry, none }

struct NativeFailurePresentation {
    let recovery: NativeRecovery
    let titleKey: String
    init(code: String) {
        switch code {
        case "LOGIN_REQUIRED": recovery = .signIn; titleKey = "status_sign_in_title"
        case "SESSION_UNRECOGNISED", "SESSION_CHANGED": recovery = .signIn; titleKey = "status_session_stale_title"
        case "CHALLENGE": recovery = .challenge; titleKey = "status_challenge_title"
        case "SIGN_IN_SUPERSEDED": recovery = .none; titleKey = "status_session_stale_title"
        case "UNSUPPORTED", "UNKNOWN_OPERATION", "UNSUPPORTED_SETTING", "UNKNOWN_ROUTE":
            recovery = .none; titleKey = "status_not_wired_title"
        case "LEVEL_REQUIRED": recovery = .none; titleKey = "status_level_required_title"
        case "PRIVATE_POST": recovery = .none; titleKey = "status_private_post_title"
        case "QUERY_TOO_SHORT": recovery = .none; titleKey = "status_query_too_short_title"
        case "RATE_LIMITED": recovery = .retry; titleKey = "status_rate_limited_title"
        case "INVALID_ARGUMENT", "INVALID_DATA", "INVALID_LINK", "INVALID_ENVELOPE":
            recovery = .none; titleKey = "native_foundation_invalid"
        case "NOT_FOUND": recovery = .none; titleKey = "status_no_results_title"
        case "NETWORK", "TRANSPORT": recovery = .retry; titleKey = "status_network_title"
        default: recovery = .retry; titleKey = "native_foundation_failure"
        }
    }
}

enum NativeLinkRouting {
    static func isSafeWebURL(_ text: String) -> Bool {
        guard !text.contains("\\"),
              text.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: text),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    static func destination(_ text: String, site: NativeSite) -> NativeDestination {
        switch NativeDeepLink.parse(text, site: site) {
        case .post(let id, let page):
            var args: [String: JSONValue] = ["postId": .integer(id), "page": .integer(Int64(page))]
            if let floor = floorFragment(text) { args["floor"] = .string(floor) }
            return NativeDestination("PostDetail", args)
        case .space(let uid): return NativeDestination("UserSpace", ["uid": .integer(uid)])
        case .messageThread(let uid): return NativeDestination("MessageThread", ["uid": .integer(uid)])
        case .notifications(let group):
            return NativeDestination("Notifications", group.map { ["group": .string($0.rawValue)] } ?? [:])
        default: return NativeDestination("Web", ["url": .string(text), "goal": .string("EXTERNAL")])
        }
    }
    private static func floorFragment(_ text: String, depth: Int = 0) -> String? {
        guard depth <= 4, let url = URLComponents(string: text) else { return nil }
        if url.path == "/jump", let target = url.queryItems?.first(where: { $0.name == "to" })?.value {
            return floorFragment(target, depth: depth + 1)
        }
        guard let fragment = url.fragment, !fragment.isEmpty,
              fragment.utf8.allSatisfy({ (48...57).contains($0) }), Int64(fragment) != nil else { return nil }
        return fragment
    }
}
