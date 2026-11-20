import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

private let reviewNow = ISO8601DateFormatter().date(from: "2026-11-16T04:00:00Z")!

// Controlled synthetic dates/UIDs; actual shipping projection, no network.
@Test func independentReceiptCannotMaskAuthoritativeNextDayUnsignedStatus() {
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .integer(14), "message": .null]), now: reviewNow)
    let nextDay: JSONValue = .object(["uid": .integer(31037), "date": .string("2026-11-17"), "hasSignedIn": .bool(false), "gain": .null])
    #expect(state.presentation(status: nextDay, isSignedIn: true, now: reviewNow) == .unsigned)
}
@Test func independentMessageOnlyReceiptCannotBorrowAnotherDayGain() {
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .null, "message": .string("done")]), now: reviewNow)
    let stale: JSONValue = .object(["uid": .integer(31037), "date": .string("2026-11-15"), "hasSignedIn": .bool(true), "gain": .integer(99)])
    // Caller has no scope parameter; stale DTO currently manufactures today's amount.
    #expect(state.presentation(status: stale, isSignedIn: true, now: reviewNow) == .signedWithoutAmount)
}
