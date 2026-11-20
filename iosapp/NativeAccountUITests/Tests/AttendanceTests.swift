import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

// All unscoped fixtures share the DTO site day, independent of wall-clock time.
private let attendanceNow = ISO8601DateFormatter().date(from: "2026-11-16T04:00:00Z")!

private func attendanceStatus(_ signed: Bool, gain: JSONValue = .null) -> JSONValue {
    .object(["uid": .integer(31037), "date": .string("2026-11-16"), "hasSignedIn": .bool(signed), "gain": gain])
}

@Test func attendanceStartupUsesAuthoritativeStatusAndGuestCannotSeeReceipt() {
    let state = AccountAttendanceState()
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(14)), isSignedIn: true, now: attendanceNow) == .reward(14))
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(0)), isSignedIn: true, now: attendanceNow) == .reward(0))
    #expect(state.presentation(status: attendanceStatus(true), isSignedIn: true, now: attendanceNow) == .signedWithoutAmount)
    #expect(state.presentation(status: attendanceStatus(false), isSignedIn: true, now: attendanceNow) == .unsigned)
    #expect(state.presentation(status: .null, isSignedIn: true, now: attendanceNow) == .unknown)
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(14)), isSignedIn: false, now: attendanceNow) == .guest)
}

@Test @MainActor func attendanceAcknowledgedRewardSurvivesReadFailureWithoutAnotherWrite() async {
    let action = AccountAction()
    var state = AccountAttendanceState()
    var status = attendanceStatus(false)
    var writes = 0
    var reads = 0
    action.perform(operation: "attendance.sign", arguments: ["mode": .string("RANDOM"), "confirmed": .bool(true)], request: { op, args in
        #expect(op == "attendance.sign")
        #expect(args["mode"] == .string("RANDOM") && args["confirmed"] == .bool(true))
        writes += 1
        return .object(["gain": .integer(14), "message": .string("签到成功")])
    }, currentGeneration: { 1 }, read: {
        reads += 1
        if reads == 1 { throw NativeFailure(code: "NETWORK", message: "") }
        status = attendanceStatus(true, gain: .integer(14))
    }, received: { state.receive($0, now: attendanceNow) })
    await eventually { action.state.phase == .savedNeedsRefresh }
    #expect(state.presentation(status: status, isSignedIn: true, now: attendanceNow) == .reward(14))
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(5)), isSignedIn: true, now: attendanceNow) == .reward(14))
    #expect(action.blocked)
    action.refreshOnly()
    await eventually { action.state.phase == .verified }
    #expect(state.presentation(status: status, isSignedIn: true, now: attendanceNow) == .reward(14))
    #expect(writes == 1 && reads == 2)
    action.cancel()
}

@Test func attendanceNeverInventsRewardFromModeBalanceMessageOrMalformedReceipt() {
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .null, "message": .string("今天已完成签到"), "current": .integer(4071), "coin": .integer(4071)]), now: attendanceNow)
    #expect(state.presentation(status: attendanceStatus(false), isSignedIn: true, now: attendanceNow) == .signedWithoutAmount)
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(6)), isSignedIn: true, now: attendanceNow) == .reward(6))
    state.reset()
    #expect(state.presentation(status: attendanceStatus(false), isSignedIn: true, now: attendanceNow) == .unsigned)
    state.receive(.null, now: attendanceNow)
    #expect(state.presentation(status: .null, isSignedIn: true, now: attendanceNow) == .unknown)
    state.receive(.object(["gain": .string("14"), "message": .null]), now: attendanceNow)
    #expect(state.presentation(status: .null, isSignedIn: true, now: attendanceNow) == .unknown)
}

@Test func attendanceDecodesExistingNativeResultJSONWithoutBalanceFallback() throws {
    var state = AccountAttendanceState()
    // NativeAccountMapping.AttendanceResult.accountDto, NOT the raw site envelope.
    let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"gain":5,"message":"签到收益5个鸡腿"}"#.utf8))
    state.receive(receipt, now: attendanceNow)
    #expect(state.presentation(status: .null, isSignedIn: true, now: attendanceNow) == .reward(5))
}

@Test @MainActor func uncertainAttendanceOnlyReconcilesThroughReadWithoutInventingReward() async {
    let action = AccountAction()
    var state = AccountAttendanceState()
    var status = attendanceStatus(false)
    var writes = 0
    action.perform(operation: "attendance.sign", arguments: ["mode": .string("FIXED_FIVE"), "confirmed": .bool(true)], request: { _, _ in
        writes += 1
        throw NativeFailure(code: "NETWORK", message: "")
    }, currentGeneration: { 1 }, read: {
        status = attendanceStatus(true, gain: .integer(5))
    }, received: { state.receive($0, now: attendanceNow) })
    await eventually { action.state.phase == .uncertain }
    #expect(state.presentation(status: status, isSignedIn: true, now: attendanceNow) == .unsigned)
    #expect(action.blocked && writes == 1)
    action.refreshOnly()
    await eventually { action.state.phase == .reconciled }
    #expect(state.presentation(status: status, isSignedIn: true, now: attendanceNow) == .reward(5))
    #expect(writes == 1)
    action.cancel()
}

@Test func attendanceScopedReceiptExpiresAtSiteMidnightWithoutTrustingDeviceZone() throws {
    let before = try #require(ISO8601DateFormatter().date(from: "2026-11-16T15:59:59Z"))
    let after = try #require(ISO8601DateFormatter().date(from: "2026-11-16T16:00:00Z"))
    let scope = AccountAttendanceState.Scope(generation: 1, identityEpoch: "A", site: "NODESEEK", uid: 31037)
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .integer(14), "message": .null]), scope: scope, day: "2026-11-16", now: before)
    #expect(AccountAttendanceState.siteDay(before) == "2026-11-16")
    #expect(AccountAttendanceState.siteDay(after) == "2026-11-17")
    #expect(state.presentation(status: attendanceStatus(true, gain: .integer(5)), isSignedIn: true, scope: scope, now: before) == .reward(14))
    #expect(state.presentation(status: attendanceStatus(false), isSignedIn: true, scope: scope, now: after) == .unknown)
    let tomorrow: JSONValue = .object(["uid": .integer(31037), "date": .string("2026-11-17"), "hasSignedIn": .bool(false), "gain": .null])
    #expect(state.presentation(status: tomorrow, isSignedIn: true, scope: scope, now: after) == .unsigned)
}

@Test func attendanceReceiptCannotCrossUIDSiteEpochOrGeneration() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-11-16T04:00:00Z"))
    let original = AccountAttendanceState.Scope(generation: 1, identityEpoch: "A", site: "NODESEEK", uid: 31037)
    var state = AccountAttendanceState()
    state.receive(.object(["gain": .integer(14), "message": .null]), scope: original, day: "2026-11-16", now: now)
    for replacement in [
        AccountAttendanceState.Scope(generation: 2, identityEpoch: "A", site: "NODESEEK", uid: 31037),
        .init(generation: 1, identityEpoch: "B", site: "NODESEEK", uid: 31037),
        .init(generation: 1, identityEpoch: "A", site: "DEEPNODE", uid: 31037),
        .init(generation: 1, identityEpoch: "A", site: "NODESEEK", uid: 99)
    ] {
        #expect(state.presentation(status: .null, isSignedIn: true, scope: replacement, now: now) == .unknown)
    }
    state.receive(.object(["gain": .null, "message": .string("done")]), scope: original, day: "2026-11-16", now: now)
    let anotherUID: JSONValue = .object(["uid": .integer(99), "date": .string("2026-11-16"), "hasSignedIn": .bool(true), "gain": .integer(99)])
    #expect(state.presentation(status: anotherUID, isSignedIn: true, scope: original, now: now) == .signedWithoutAmount)
}

@Test @MainActor func attendanceLateReceiptAfterCancellationOrAccountChangeIsNotPublished() async {
    for cancel in [false, true] {
        let action = AccountAction()
        var state = AccountAttendanceState()
        var generation = 1
        var pending: CheckedContinuation<JSONValue, Never>?
        var reads = 0
        action.perform(operation: "attendance.sign", arguments: [:], request: { _, _ in
            await withCheckedContinuation { pending = $0 }
        }, currentGeneration: { generation }, read: { reads += 1 }, received: { state.receive($0, now: attendanceNow) })
        await eventually { pending != nil }
        if cancel { action.cancel() } else { generation = 2 }
        pending?.resume(returning: .object(["gain": .integer(14), "message": .null]))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(state.presentation(status: .null, isSignedIn: true, now: attendanceNow) == .unknown)
        #expect(reads == 0)
        action.cancel()
    }
}
