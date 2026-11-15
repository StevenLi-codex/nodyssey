import Foundation
import NodysseyNativeCore

enum AccountInputState {
    /// Presentation-only port of ui/account/PasswordStrength.kt; never a save gate.
    /// Iterate UTF-16 units, like Kotlin Char (including surrogate symbol handling).
    static func passwordStrength(_ password: String) -> String? {
        guard !password.isEmpty else { return nil }
        var lower = false, upper = false, digit = false, symbol = false
        for unit in password.utf16 {
            guard let scalar = Unicode.Scalar(unit) else { symbol = true; continue }
            let category = scalar.properties.generalCategory
            lower = lower || scalar.properties.isLowercase
            upper = upper || scalar.properties.isUppercase
            digit = digit || category == .decimalNumber
            let letterOrDigit = [.uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber].contains(category)
            let whitespace = [.spaceSeparator, .lineSeparator, .paragraphSeparator].contains(category)
                || (9...13).contains(unit) || (28...31).contains(unit)
            symbol = symbol || (!letterOrDigit && !whitespace)
        }
        let classes = [lower, upper, digit, symbol].filter { $0 }.count
        let score = [8, 12, 16, 20].filter { password.utf16.count >= $0 }.count + classes - 1
        switch score {
        case 6...7: return "best"
        case 4...5: return "strong"
        case 2...3: return "fair"
        default: return "weak"
        }
    }
    static func validPassword(current: String, new: String, confirmation: String) -> Bool {
        !current.isEmpty && new.utf16.count >= 8 && new == confirmation
    }
    static func avatar(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= 6_291_456 else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "") }
        let bytes = [UInt8](data.prefix(8))
        if bytes.starts(with: [137,80,78,71,13,10,26,10]) { return "image/png" }
        if bytes.starts(with: [255,216,255]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return "image/gif" }
        throw NativeFailure(code: "INVALID_ARGUMENT", message: "")
    }
}

struct AccountPageState {
    private(set) var items: [JSONValue] = []
    private(set) var page: Int64 = 1
    private(set) var hasNext = false
    private var ticket = UUID()
    private var requested: Int64 = 1
    mutating func begin(page: Int64) -> UUID { requested = page; ticket = UUID(); return ticket }
    // Navigation away cancels in-flight publication, not the loaded page.
    mutating func suspend() { ticket = UUID() }
    mutating func invalidate() { ticket = UUID(); items = []; page = 1; hasNext = false }
    @discardableResult mutating func accept(_ value: JSONValue, ticket id: UUID) throws -> Bool {
        guard id == ticket else { return false }
        guard let page = value["page"]?.int, page > 0, page == requested, let rows = value["items"]?.array,
              let next = value["hasNextPage"]?.bool,
              rows.allSatisfy({ ($0["postId"]?.int ?? 0) > 0 }) else { throw NativeFailure(code: "INVALID_DATA", message: "") }
        self.page = page; items = rows; hasNext = next; return true
    }
    func filtered(query: String, board: String, newestFirst: Bool) -> [JSONValue] {
        let rows = items.filter { row in
            (board.isEmpty || row["categorySlug"]?.string == board) && (query.isEmpty ||
                ["title", "postTitle", "excerpt"].contains { row[$0]?.string?.localizedCaseInsensitiveContains(query) == true })
        }
        return newestFirst ? rows : Array(rows.reversed())
    }
}
