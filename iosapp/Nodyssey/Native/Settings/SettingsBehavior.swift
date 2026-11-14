import Foundation
import NodysseyNativeCore

struct SettingsReleaseNotes: Identifiable {
    let id: String
    let version: String
    let published: String
    let preRelease: Bool
    let text: String
    let url: URL?

    static func decode(_ value: JSONValue) throws -> [SettingsReleaseNotes] {
        guard let rows = value["releases"]?.array else {
            throw NativeFailure(code: "INVALID_DATA", message: "Missing release history")
        }
        return try rows.map { row in
            guard let tag = row["tag"]?.string, !tag.isEmpty,
                  let version = row["versionName"]?.string, let published = row["publishedOn"]?.string,
                  let preview = row["preRelease"]?.bool, let text = row["text"]?.string else {
                throw NativeFailure(code: "INVALID_DATA", message: "Invalid release entry")
            }
            let candidate = row["htmlUrl"]?.string.flatMap(URL.init(string:))
            let safe = candidate.flatMap { url -> URL? in
                guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
                      url.port == nil || url.port == 443,
                      url.path.hasPrefix("/5151561/nodyssey/releases/tag/") else { return nil }
                return url
            }
            return SettingsReleaseNotes(id: tag, version: version, published: published, preRelease: preview, text: text, url: safe)
        }
    }
}

enum SettingsColor {
    static func argb(_ text: String) -> Int64? {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard digits.utf8.count == 6, digits.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let rgb = UInt32(digits, radix: 16) else { return nil }
        return Int64(Int32(bitPattern: 0xFF000000 | rgb))
    }
    static func hex(_ argb: Int64) -> String {
        String(format: "#%06X", UInt32(truncatingIfNeeded: argb) & 0xFFFFFF)
    }
}

struct SettingsRequestGate {
    private var current: UUID?
    var isBusy: Bool { current != nil }
    mutating func begin() -> UUID? {
        guard current == nil else { return nil }
        let token = UUID()
        current = token
        return token
    }
    mutating func finish(_ token: UUID) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }
    mutating func invalidate() { current = nil }
}

enum SettingsDohSelection {
    static func select(_ id: String, servers: [JSONValue]) throws -> [JSONValue] {
        guard servers.contains(where: { $0["id"]?.string == id }) else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "Missing resolver")
        }
        return servers.map { server in
            var fields = server.object ?? [:]
            fields["checked"] = .bool(server["id"]?.string == id)
            return .object(fields)
        }
    }
}

/// Input-only draft. Never reconstruct a password from the redacted repository snapshot.
struct SettingsProxyDraft: Equatable {
    var type: String
    var host: String
    var port: String
    var username: String
    var scope: String
    var password = ""
    var passwordChanged = false

    init(snapshot: JSONValue) {
        type = snapshot["type"]?.string ?? "HTTP"
        host = snapshot["host"]?.string ?? ""
        port = snapshot["port"]?.int.map(String.init) ?? ""
        username = snapshot["username"]?.string ?? ""
        scope = snapshot["scope"]?.string ?? "EVERYTHING"
    }

    func payload() throws -> [String: JSONValue] {
        guard !port.isEmpty, port.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(port), (1...65535).contains(value),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "Invalid proxy endpoint")
        }
        var fields: [String: JSONValue] = [
            "type": .string(type), "host": .string(host.trimmingCharacters(in: .whitespacesAndNewlines)),
            "port": .integer(value), "username": .string(username), "scope": .string(scope)
        ]
        if passwordChanged { fields["password"] = .string(password) }
        return fields
    }
}
