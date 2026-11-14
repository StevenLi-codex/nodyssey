import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@MainActor @Test func paymentRequiresConfirmationAndReadsLedgerAfterUncertainWrite() async throws {
    let draft = try LibraryPayment(recipient: "9007199254740993", amount: "8", refId: "0", onetime: true)
    var operations: [String] = []
    let request: LibraryRequest = { op, _ in
        operations.append(op)
        if op == "assets.transfer" { throw NativeFailure(code: "NETWORK", message: "") }
        return .array([])
    }
    do {
        _ = try await LibraryOperations.pay(draft, confirmed: false, request: request)
        Issue.record("Unconfirmed payment must fail")
    } catch {}
    #expect(operations.isEmpty)
    let outcome = try await LibraryOperations.pay(draft, confirmed: true, request: request)
    #expect(!outcome.acknowledged)
    #expect(outcome.writeFailure?.code == "NETWORK")
    #expect(operations == ["profile.self", "assets.transfer", "assets.stardust", "profile.self", "assets.growth"])
}

@MainActor @Test func acknowledgedPaymentIsNotRelabelledFailedWhenReadbackFails() async throws {
    let draft = try LibraryPayment(recipient: "4", amount: "8", refId: "5", onetime: false)
    var written = false
    let outcome = try await LibraryOperations.pay(draft, confirmed: true) { op, _ in
        if written { throw NativeFailure(code: "NETWORK", message: "") }
        if op == "assets.transfer" { written = true }
        return .null
    }
    #expect(outcome.acknowledged)
    #expect(outcome.writeFailure == nil)
    #expect(outcome.refreshFailure?.code == "NETWORK")
}

@MainActor @Test func accountChangeDuringPaymentReadbackNeverReturnsOldLedger() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    var didThrow = false
    do {
        _ = try await LibraryOperations.pay(payment, confirmed: true) { op, _ in
            if op == "assets.growth" { throw NativeFailure(code: "SESSION_CHANGED", message: "") }
            return op == "assets.stardust" ? .object(["items": .array([.object(["id": .integer(99)])])]) : .null
        }
    } catch let error as NativeFailure { didThrow = error.code == "SESSION_CHANGED" }
    #expect(didThrow)
}

@Test func reportSelectionUsesWholeEntryNotStaleArrayPosition() throws {
    let a: JSONValue = .object(["postId": .integer(9_007_199_254_740_993), "report": .object(["title": .string("same")])])
    let b: JSONValue = .object(["postId": .integer(7), "report": .object(["title": .string("same")])])
    var selection = LibraryReportSelection()
    selection.toggle(a); selection.toggle(b)
    #expect(try selection.entries(in: [b, a]) == [b, a])
    #expect(throws: NativeFailure.self) { try selection.entries(in: [b]) }
}

@Test func downloadedFilterIncludesStaleAndPreservesSiteOrder() {
    let rows: [JSONValue] = [1, 2, 3].map { .object(["postId": .integer($0), "title": .string("thread")]) }
    let offline: JSONValue = .object(["states": .array([
        .object(["postId": .integer(1), "state": .string("Stale")]),
        .object(["postId": .integer(3), "state": .string("Downloaded")])])])
    #expect(LibraryRows.visible(rows, offline: offline, query: "", filter: "downloaded", sort: "site").compactMap { $0["postId"]?.int } == [1, 3])
}

@Test func receiveMarkerPreservesAllFieldsAndRejectsIncompleteIdentity() throws {
    let route: [String: JSONValue] = ["memberId": .integer(9_007_199_254_740_993), "amount": .integer(17), "refId": .integer(8), "onetime": .bool(true)]
    let payment = try LibraryPayment(route: route)
    #expect(payment.recipient == 9_007_199_254_740_993)
    #expect(payment.amount == 17)
    #expect(payment.refId == 8)
    #expect(payment.onetime)
    #expect(throws: NativeFailure.self) { try LibraryPayment(route: ["memberId": .integer(4)]) }
}

@Test func invalidPaymentNeverRoundsOrDefaultsIdentity() {
    #expect(throws: NativeFailure.self) { try LibraryPayment(recipient: "9.0", amount: "8", refId: "0", onetime: false) }
    #expect(throws: NativeFailure.self) { try LibraryPayment(recipient: "9", amount: "0", refId: "0", onetime: false) }
}
