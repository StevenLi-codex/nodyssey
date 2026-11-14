import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition(), "Timed out waiting for coordinator")
}

@Test @MainActor func passwordCoordinatorDoesNotTreatStatusReadAsPasswordProof() async {
    let action = AccountAction()
    var writes = 0
    var reads = 0
    action.perform(operation: "account.changePassword", arguments: [:], request: { _, _ in
        writes += 1; throw NativeFailure(code: "NETWORK", message: "")
    }, currentGeneration: { 1 }, read: { reads += 1 })
    await eventually { action.state.phase == .uncertain }
    action.refreshOnly()
    await eventually { reads == 1 && action.failure == nil }
    #expect(action.state.phase == .uncertain)
    #expect(action.blocked)
    #expect(writes == 1)
    action.cancel()
}

@Test @MainActor func genericBridgeFailuresRemainUnknownAndHaveExplicitReadOnlyRecovery() async {
    for code in ["INVALID_ARGUMENT", "INTERNAL", "AUTH_REQUIRED", "NETWORK", "TRANSPORT"] {
        let action = AccountAction()
        var writes = 0
        var reads = 0
        action.perform(operation: "account.holidayTheme", arguments: [:], request: { _, _ in
            writes += 1; throw NativeFailure(code: code, message: "untrusted detail")
        }, currentGeneration: { 1 }, read: { reads += 1 })
        await eventually { action.state.phase == .uncertain }
        #expect(action.blocked && action.canRefresh)
        #expect(action.failure?.message == "")
        action.refreshOnly()
        await eventually { action.state.phase == .reconciled }
        #expect(!action.blocked)
        #expect(action.state.phase != .verified)
        #expect(writes == 1 && reads == 1)
        action.cancel()
    }
}

@Test @MainActor func successfulAcknowledgementNeedsReadbackAndRetryNeverRepeatsWrite() async {
    let action = AccountAction()
    var writes = 0
    var reads = 0
    var received = 0
    action.perform(operation: "account.changePassword", arguments: [:], request: { _, _ in
        writes += 1; return .object([:])
    }, currentGeneration: { 1 }, read: {
        reads += 1
        if reads == 1 { throw NativeFailure(code: "NETWORK", message: "") }
    }, received: { _ in received += 1 })
    await eventually { action.state.phase == .savedNeedsRefresh }
    #expect(received == 1 && action.blocked && action.canRefresh)
    action.refreshOnly()
    await eventually { action.state.phase == .verified }
    #expect(writes == 1 && reads == 2)
    action.cancel()
}

@Test @MainActor func readOnlyRecoveryIsSingleFlightAndGenerationScoped() async {
    let action = AccountAction()
    var generation = 1
    var reads = 0
    var pending: [CheckedContinuation<Void, Never>] = []
    action.perform(operation: "account.holidayTheme", arguments: [:], request: { _, _ in .object([:]) },
                   currentGeneration: { generation }, read: {
        reads += 1
        if reads == 1 { throw NativeFailure(code: "NETWORK", message: "") }
        await withCheckedContinuation { pending.append($0) }
    })
    await eventually { action.state.phase == .savedNeedsRefresh }
    action.refreshOnly(); action.refreshOnly()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(reads == 2)
    generation = 2
    pending.forEach { $0.resume() }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(action.state.phase != .verified)
    #expect(action.failure?.code == "NETWORK")
    let count = reads
    action.refreshOnly()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(reads == count)
    // Drain any buggy old-generation start so this regression cannot leak a task.
    if reads > count { pending.last?.resume() }
    action.cancel()
}

@Test @MainActor func malformedRegexIsRejectedBeforeWriteAndCorrectedInputCanSubmit() async {
    let action = AccountAction()
    var writes = 0
    let request: (String, [String: JSONValue]) async throws -> JSONValue = { _, _ in
        writes += 1; throw NativeFailure(code: "INVALID_ARGUMENT", message: "")
    }
    action.perform(operation: "keywords.add", arguments: ["kind": .string("BLOCK_REGEX"), "text": .string("[")],
                   request: request, currentGeneration: { 1 }, read: {})
    await eventually { action.failure != nil }
    #expect(writes == 0)
    #expect(!action.blocked)
    action.perform(operation: "keywords.add", arguments: ["kind": .string("BLOCK_REGEX"), "text": .string("reader.*")],
                   request: { _, _ in writes += 1; return .array([.string("reader.*")]) }, currentGeneration: { 1 }, read: {})
    await eventually { action.state.phase == .verified }
    #expect(writes == 1)
    action.cancel()
}
