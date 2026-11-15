import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@MainActor @Test func idlePreflightFailureCanCloseWithoutAnUncertainWrite() async throws {
    let recovery = LibraryPaymentRecovery()
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "1", onetime: false)
    var writes = 0
    let result = try await recovery.pay(payment) { op, _ in
        if op == "assets.transfer" { writes += 1 }
        throw NativeFailure(code: "NETWORK", message: "")
    }
    #expect(result.preflightFailure?.code == "NETWORK")
    #expect(writes == 0)
    #expect(recovery.frozenPayment == nil)
    #expect(!recovery.needsReadback)
    #expect(recovery.canDismiss(isBusy: false))
    #expect(recovery.canLeaveRoute(isBusy: false))
}

@MainActor @Test func uncertainReadbackCloseReopenCannotDispatchAgain() async throws {
    let owner = LibraryPaymentRecovery()
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "1", onetime: false)
    var writes = 0
    let request: LibraryRequest = { op, _ in
        if op == "profile.self" { return .object(["starCount": .integer(8)]) }
        if op == "assets.transfer" { writes += 1 }
        throw NativeFailure(code: "NETWORK", message: "")
    }
    let result = try await owner.pay(payment, request: request)
    #expect(result.writeAttempted && result.refreshFailure != nil)
    #expect(owner.canDismiss(isBusy: false))
    // SwiftUI presents the same destination-owned StateObject on reopening.
    let reopened = owner
    #expect(reopened.frozenPayment == payment)
    #expect(reopened.needsReadback)
    #expect(!reopened.canLeaveRoute(isBusy: false))
    do {
        _ = try await reopened.pay(payment, request: request)
        Issue.record("Reopening must not admit an unresolved duplicate")
    } catch let failure as NativeFailure { #expect(failure.code == "NOT_CONFIRMED") }
    #expect(writes == 1)
    reopened.reconcile(payment, authoritativePaid: false)
    #expect(reopened.needsReadback)
    #expect(!reopened.canPay(payment))
}

@MainActor @Test func actualSuspendedWriteBlocksCloseAndReconciliationNeedsAuthority() async throws {
    let owner = LibraryPaymentRecovery()
    let payment = try LibraryPayment(recipient: "4", amount: "8", refId: "1", onetime: false)
    var writer: CheckedContinuation<Void, Never>?
    var writes = 0
    let operation = Task { @MainActor in
        try await owner.pay(payment) { op, _ in
            if op == "profile.self" { return .object(["starCount": .integer(8)]) }
            if op == "assets.transfer" {
                writes += 1
                await withCheckedContinuation { writer = $0 }
                return .object([:])
            }
            throw NativeFailure(code: "NETWORK", message: "")
        }
    }
    while writer == nil { await Task.yield() }
    #expect(!owner.canDismiss(isBusy: false))
    #expect(!owner.canLeaveRoute(isBusy: false))
    #expect(!owner.canPay(payment))
    writer?.resume()
    let result = try await operation.value
    #expect(result.acknowledged && result.refreshFailure != nil)
    #expect(owner.canDismiss(isBusy: false))
    #expect(owner.needsReadback)
    let wrong = try LibraryPayment(recipient: "5", amount: "8", refId: "1", onetime: false)
    owner.reconcile(wrong, authoritativePaid: true)
    #expect(owner.needsReadback)
    owner.reconcile(payment, authoritativePaid: false)
    #expect(owner.needsReadback)
    owner.reconcile(payment, authoritativePaid: owner.acknowledged)
    #expect(!owner.needsReadback)
    #expect(owner.canLeaveRoute(isBusy: false))
    #expect(!owner.canPay(payment))
    #expect(writes == 1)
}
