import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

// Controlled synthetic dates/UIDs; actual shipping projection, no network.
@Test func independentReceiptCannotMaskAuthoritativeNextDayUnsignedStatus() {
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .integer(14), "message": .null]))
    let nextDay: JSONValue = .object(["uid": .integer(31037), "date": .string("2026-11-17"), "hasSignedIn": .bool(false), "gain": .null])
    #expect(state.presentation(status: nextDay, isSignedIn: true) == .unsigned)
}
@Test func independentMessageOnlyReceiptCannotBorrowAnotherDayGain() {
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .null, "message": .string("done")]))
    let stale: JSONValue = .object(["uid": .integer(31037), "date": .string("2026-11-15"), "hasSignedIn": .bool(true), "gain": .integer(99)])
    // Caller has no scope parameter; stale DTO currently manufactures today's amount.
    #expect(state.presentation(status: stale, isSignedIn: true) == .signedWithoutAmount)
}
