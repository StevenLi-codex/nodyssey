import Foundation
import NodysseyNativeCore

struct NativeDestination: Identifiable, Hashable, Sendable {
    let id = UUID()
    let route: String
    let arguments: [String: JSONValue]
    init(_ route: String, _ arguments: [String: JSONValue] = [:]) {
        self.route = route
        self.arguments = arguments
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum NativeTab: String, CaseIterable, Sendable { case home, notifications, profile }

extension JSONValue {
    func nativeString(_ key: String) -> String? { self[key]?.string }
    func nativeInt(_ key: String) -> Int64? { self[key]?.int }
    func nativeBool(_ key: String) -> Bool? { self[key]?.bool }
    func nativeArray(_ key: String) -> [JSONValue] { self[key]?.array ?? [] }
    func nativeEncoded() throws -> Data { try JSONEncoder().encode(self) }
}
