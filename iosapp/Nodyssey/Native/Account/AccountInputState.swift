import Foundation
import NodysseyNativeCore

enum AccountInputState {
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
