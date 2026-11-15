import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@Test func shortfallUsesNullableBalanceAndExactIntegerArithmetic() throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    #expect(payment.shortfall(balance: nil) == nil)
    #expect(payment.shortfall(balance: 0) == 8)
    #expect(payment.shortfall(balance: 3) == 5)
    #expect(payment.shortfall(balance: 8) == nil)
    #expect(payment.shortfall(balance: 9) == nil)
    let large = try LibraryPayment(recipient: "4", amount: "9007199254740993", refId: "0", onetime: false)
    #expect(large.shortfall(balance: 9_007_199_254_740_992) == 1)
    #expect(large.shortfall(balance: Int64.min) == Int64.max)
}

@MainActor @Test func unknownBalanceDoesNotBecomeZeroAndExactBalanceCanBeSpent() async throws {
    for balance: JSONValue in [.null, .integer(8), .integer(9)] {
        let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
        var writes = 0
        let result = try await LibraryOperations.pay(payment, confirmed: true) { op, _ in
            if op == "profile.self" { return .object(["uid": .integer(2), "starCount": balance]) }
            if op == "assets.transfer" { writes += 1 }
            return .null
        }
        #expect(writes == 1)
        #expect(result.acknowledged)
    }
}

@MainActor @Test func profileReadFailureBeforePaymentCannotBeTreatedAsUnknownBalance() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    var writes = 0
    let result = try await LibraryOperations.pay(payment, confirmed: true) { op, _ in
        if op == "profile.self" { throw NativeFailure(code: "NETWORK", message: "") }
        if op == "assets.transfer" { writes += 1 }
        return .null
    }
    #expect(result.preflightFailure?.code == "NETWORK")
    #expect(!result.writeAttempted)
    #expect(writes == 0)
}

@MainActor @Test func paymentRecoveryAllowsIdleCloseButBlocksTheFrozenIntent() throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    let recovery = LibraryPaymentRecovery()
    recovery.markWriteAttempted(payment)

    #expect(recovery.needsReadback)
    #expect(recovery.canDismiss(isBusy: false))
    #expect(!recovery.canPay(payment))

    recovery.reconcile(payment, authoritativePaid: true)
    #expect(!recovery.needsReadback)
    #expect(!recovery.canPay(payment))
}

@MainActor @Test func missingReceiptCannotReleaseAnUncertainPayment() throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    let other = try LibraryPayment(recipient: "5", amount: "8", refId: "0", onetime: false)
    let recovery = LibraryPaymentRecovery()
    recovery.markWriteAttempted(payment)
    recovery.reconcile(payment, authoritativePaid: false)

    #expect(recovery.needsReadback)
    #expect(!recovery.canPay(payment))
    #expect(!recovery.canPay(other))
    #expect(!recovery.canLeaveRoute(isBusy: false))
    #expect(recovery.frozenPayment == payment)
}

@MainActor @Test func indeterminateWriteStaysFrozenWhenReadbackFails() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    var transferCalls = 0
    let result = try await LibraryOperations.pay(payment, confirmed: true) { op, _ in
        if op == "assets.transfer" {
            transferCalls += 1
            throw NativeFailure(code: "NETWORK", message: "")
        }
        if op == "assets.stardust" { throw NativeFailure(code: "NETWORK", message: "") }
        if op == "profile.self" { return .object(["starCount": .integer(8)]) }
        return .null
    }
    #expect(result.writeAttempted)
    #expect(result.writeFailure?.code == "NETWORK")
    #expect(result.refreshFailure?.code == "NETWORK")
    #expect(transferCalls == 1)
}

@MainActor @Test func profileRefreshFailureRetainsAcknowledgementButNotStaleGrowth() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    for attendance in [false, true] {
        var written = false
        let request: LibraryRequest = { op, args in
            if op == "assets.transfer" || op == "attendance.sign" { written = true; return .null }
            if written && op == "profile.self" {
                #expect(args["refresh"] == .bool(true))
                throw NativeFailure(code: "NETWORK", message: "")
            }
            if op == "assets.growth" { Issue.record("Never publish cached growth after failed forced refresh") }
            return .null
        }
        if attendance {
            let result = try await LibraryOperations.signAttendance(mode: "FIXED_FIVE", request: request)
            #expect(result.acknowledged && result.writeFailure == nil)
            #expect(result.refreshFailure?.code == "NETWORK")
            #expect(result.growth == .null)
        } else {
            let result = try await LibraryOperations.pay(payment, confirmed: true, request: request)
            #expect(result.acknowledged && result.writeFailure == nil)
            #expect(result.refreshFailure?.code == "NETWORK")
            #expect(result.growth == .null)
        }
    }
}

@MainActor @Test func sessionChangeAndCancellationStopEveryMutationReadbackPhase() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    for attendance in [false, true] {
        for phase in ["write", "ledger", "profile", "growth"] {
            for cancelled in [false, true] {
                var written = false
                var writes = 0
                var interrupted = false
                let request: LibraryRequest = { op, _ in
                    #expect(!interrupted)
                    let write = op == "assets.transfer" || op == "attendance.sign"
                    if write { written = true; writes += 1 }
                    let stop = (phase == "write" && write) || (written && ((phase == "profile" && op == "profile.self") || (phase == "growth" && op == "assets.growth") || (phase == "ledger" && ["assets.stardust", "attendance.status"].contains(op))))
                    if stop {
                        interrupted = true
                        if cancelled { throw CancellationError() }
                        throw NativeFailure(code: "SESSION_CHANGED", message: "")
                    }
                    return .null
                }
                do {
                    if attendance { _ = try await LibraryOperations.signAttendance(mode: "FIXED_FIVE", request: request) }
                    else { _ = try await LibraryOperations.pay(payment, confirmed: true, request: request) }
                    Issue.record("Invalidated sequence returned an outcome")
                } catch is CancellationError { #expect(cancelled) }
                catch let error as NativeFailure { #expect(!cancelled && error.code == "SESSION_CHANGED") }
                #expect(writes == 1)
            }
        }
    }
}

@MainActor @Test func knownInsufficientBalanceCannotSendEvenAfterConfirmation() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "0", onetime: false)
    var writes = 0
    do {
        _ = try await LibraryOperations.pay(payment, confirmed: true) { op, args in
            if op == "profile.self" {
                #expect(args["refresh"] == .bool(true))
                return .object(["uid": .integer(2), "starCount": .integer(3)])
            }
            if op == "assets.transfer" { writes += 1 }
            return .null
        }
        Issue.record("Known shortfall must refuse the confirmed payment")
    } catch let error as NativeFailure { #expect(error.code == "INSUFFICIENT_BALANCE") }
    #expect(writes == 0)
}

@MainActor @Test func receiveTallyIncludesOtherPayersButOwnPaymentRemainsIndependent() async throws {
    let payment = try LibraryPayment(recipient: "9007199254740993", amount: "8", refId: "9007199254740995", onetime: true)
    // Same peer can pay twice; baseline count is receipt rows, not unique peers.
    let all: [JSONValue] = [8, 8, -3, 0, 12].enumerated().map { index, diff in
        .object(["id": .integer(Int64(index + 1)), "diff": .integer(Int64(diff)), "peerUid": .integer(7)])
    }
    for mine in [[], [all[0]]] {
        let summary = try await LibraryOperations.receipts(for: payment, ownUID: 42) { op, args in
            #expect(op == "assets.receipts")
            #expect(args["memberId"]?.int == 9_007_199_254_740_993)
            #expect(args["refId"]?.int == 9_007_199_254_740_995)
            if let peer = args["peerId"]?.int { #expect(peer == 42); return .array(mine) }
            return .array(all)
        }
        #expect(summary.payerCount == 5)
        #expect(summary.received == 28)
        #expect(summary.paidByMe == !mine.isEmpty)
        #expect(summary.mine == mine)
    }
}

@MainActor @Test func tallyFailureCannotClaimZeroOrUnpaid() async throws {
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "1", onetime: true)
    for code in ["NETWORK", "SESSION_CHANGED"] {
        do {
            _ = try await LibraryOperations.receipts(for: payment, ownUID: 2) { _, args in
                if args["peerId"] != nil { throw NativeFailure(code: code, message: "") }
                return .array([.object(["diff": .integer(8)])])
            }
            Issue.record("Partial tally must not return a paid/unpaid decision")
        } catch let error as NativeFailure { #expect(error.code == code) }
    }
}
