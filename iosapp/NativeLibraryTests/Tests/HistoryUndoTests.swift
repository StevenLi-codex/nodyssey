import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@MainActor @Test func failedHistoryRestoreKeepsReceiptButAcknowledgedRestoreConsumesItBeforeReadback() async throws {
    let undo = LibraryHistoryUndo()
    try undo.record(.object(["undoId": .string("opaque-fixture-token")]))
    do { _ = try await undo.restore { _, _ in throw NativeFailure(code: "NETWORK", message: "") } } catch {}
    #expect(undo.latest != nil)
    var sent: [String: JSONValue] = [:]
    do {
        _ = try await undo.restore { op, args in
            if op == "history.restore" { sent = args; return .object([:]) }
            throw NativeFailure(code: "NETWORK", message: "")
        }
    } catch {}
    #expect(sent == ["undoId": .string("opaque-fixture-token")])
    #expect(undo.latest == nil)
}

@MainActor @Test func expiredOrInvalidatedHistoryReceiptIsNeverSent() async throws {
    var now = Date(timeIntervalSince1970: 1000)
    let undo = LibraryHistoryUndo(clock: { now })
    try undo.record(.object(["undoId": .string("first")]))
    now = now.addingTimeInterval(301)
    #expect(undo.latest == nil)
    var writes = 0
    do { _ = try await undo.restore { _, _ in writes += 1; return .null } } catch {}
    #expect(writes == 0)
    try undo.record(.object(["undoId": .string("second")]))
    undo.reset()
    #expect(undo.latest == nil)
}
