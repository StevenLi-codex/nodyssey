import Foundation

public enum NativeSite: String, Codable, Sendable {
    case nodeSeek = "NODESEEK"
    case deepFlood = "DEEPFLOOD"

    fileprivate var hosts: Set<String> {
        switch self {
        case .nodeSeek: return ["nodeseek.com", "www.nodeseek.com"]
        case .deepFlood: return ["deepflood.com", "www.deepflood.com"]
        }
    }
}

public enum NativeNotificationGroup: String, Hashable, Sendable {
    case mentions, messages
}

public enum NativeRoute: Hashable, Sendable {
    case post(id: Int64, page: Int)
    case space(uid: Int64)
    case member(name: String)
    case notifications(group: NativeNotificationGroup?)
    case messageThread(uid: Int64)
}

/// Native navigation only; this is NOT a WebView/cookie trust policy.
public enum NativeDeepLink {
    public static func parse(_ text: String, site: NativeSite = .nodeSeek) -> NativeRoute? {
        parse(text, site: site, remainingJumps: 4)
    }

    private static func parse(_ text: String, site: NativeSite, remainingJumps: Int) -> NativeRoute? {
        guard !text.contains("\\"),
              text.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              let url = URLComponents(string: text),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), site.hosts.contains(host),
              url.percentEncodedHost?.lowercased() == host,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == (scheme == "https" ? 443 : 80) else { return nil }
        // Compare the complete encoded path: neither query substrings nor encoded separators are routes.
        let path = url.percentEncodedPath
        if path.hasPrefix("/post-") {
            let parts = path.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let id = positiveInteger(String(parts[0])) else { return nil }
            var page = 1
            if parts.count == 2 {
                guard let number = positiveInteger(String(parts[1])), let exact = Int(exactly: number) else { return nil }
                page = exact
            }
            return .post(id: id, page: page)
        }
        if path.hasPrefix("/space/"), let uid = positiveInteger(String(path.dropFirst(7))) { return .space(uid: uid) }
        if path == "/member", let name = uniqueParameter("t", in: url), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .member(name: name)
        }
        if path == "/notification" || path == "/notification/" {
            let fragment = url.fragment ?? ""
            guard let hash = URLComponents(string: "https://fragment.invalid/" + fragment.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else { return nil }
            switch hash.path.lowercased() {
            case "/atme": return .notifications(group: .mentions)
            case "/message":
                if let to = uniqueParameter("to", in: hash), let uid = positiveInteger(to) { return .messageThread(uid: uid) }
                return .notifications(group: .messages)
            default: return .notifications(group: nil)
            }
        }
        if path == "/jump", remainingJumps > 0, let target = uniqueParameter("to", in: url) {
            return parse(target, site: site, remainingJumps: remainingJumps - 1)
        }
        return nil
    }

    private static func uniqueParameter(_ key: String, in url: URLComponents) -> String? {
        let values = url.queryItems?.filter { $0.name == key } ?? []
        guard values.count == 1 else { return nil }
        return values[0].value
    }

    private static func positiveInteger(_ text: String) -> Int64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(text), value > 0 else { return nil }
        return value
    }
}
