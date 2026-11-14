import Foundation

enum AccountLinkState {
    static func resolve(_ text: String, origin: String?, floor: String? = nil) -> String? {
        guard !text.hasPrefix("//"), !text.contains("\\"),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }
        let base = origin.flatMap(URL.init(string:))
        guard let url = URL(string: text, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return nil }
        if parts.fragment == nil, let floor, !floor.isEmpty, floor.utf8.allSatisfy({ (48...57).contains($0) }) { parts.fragment = floor }
        return parts.string
    }
}
