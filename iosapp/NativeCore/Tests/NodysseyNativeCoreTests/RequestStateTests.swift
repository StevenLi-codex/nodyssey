import Foundation
import Testing
@testable import NodysseyNativeCore

/// Deliberately ignores cancellation to exercise state fences, not adapter fences.
actor SyntheticSuspendedTransport: NativeTransport {
    private var pending: [CheckedContinuation<JSONValue, Error>] = []
    private(set) var arguments: [[String: JSONValue]] = []
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        self.arguments.append(arguments)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    nonisolated func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func complete(_ index: Int, _ result: Result<JSONValue, Error>) { pending[index].resume(with: result) }
    func waitForCalls(_ count: Int) async throws {
        for _ in 0..<2000 {
            if pending.count >= count { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NativeFailure(code: "TEST_TIMEOUT", message: "Synthetic request was not started")
    }
}

struct RequestStateTests {
    @Test @MainActor func observationPublishesEachSnapshotAndInvalidationErasesAccountData() async throws {
        let bridge = SyntheticBridge()
        let state = NativeRequestState()
        var snapshots: [JSONValue?] = []
        state.onChange = { snapshots.append(state.value) }
        let observing = Task { await state.observe(using: bridge.transport, operation: "session") }
        try await eventually { bridge.calls.count == 1 }
        bridge.callbacks[0](#"{"ok":true,"data":"account A"}"#)
        try await eventually { state.value == .string("account A") }
        bridge.callbacks[0](#"{"ok":true,"data":"updated A"}"#)
        try await eventually { state.value == .string("updated A") }
        state.invalidate()
        await observing.value
        bridge.callbacks[0](#"{"ok":true,"data":"late private data"}"#)
        #expect(state.value == nil)
        #expect(state.failure == nil)
        #expect(!state.isLoading)
        #expect(snapshots.contains(.string("account A")))
        #expect(snapshots.contains(.string("updated A")))
        #expect(snapshots.last == .some(nil))
        #expect(bridge.cancellations.value == 1)
    }

    @Test @MainActor func invalidationNeverNotifiesObserversWithOldPrivateData() async throws {
        let bridge = SyntheticBridge()
        let state = NativeRequestState()
        let loading = Task { await state.load(using: bridge.transport, operation: "account") }
        try await eventually { bridge.calls.count == 1 }
        bridge.callbacks[0](#"{"ok":true,"data":"private account"}"#)
        await loading.value
        var emitted: [JSONValue?] = []
        state.onChange = { emitted.append(state.value) }
        state.invalidate()
        #expect(!emitted.isEmpty)
        #expect(emitted.allSatisfy { $0 == nil })
    }

    @Test @MainActor func olderLoadCannotOverwriteNewerResult() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeRequestState()
        let old = Task { await state.load(using: transport, operation: "page", arguments: ["page": .integer(1)]) }
        try await transport.waitForCalls(1)
        #expect(state.isLoading)
        let new = Task { await state.load(using: transport, operation: "page", arguments: ["page": .integer(2)]) }
        try await transport.waitForCalls(2)
        await transport.complete(1, .success(.string("new page")))
        await new.value
        await transport.complete(0, .success(.string("old page")))
        await old.value
        #expect(state.value == .string("new page"))
        #expect(!state.isLoading)
        #expect(state.failure == nil)
    }

    @Test @MainActor func logoutInvalidationClearsDataAndRejectsLateAccountCompletion() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeRequestState()
        let old = Task { await state.load(using: transport, operation: "account") }
        try await transport.waitForCalls(1)
        state.invalidate()
        let new = Task { await state.load(using: transport, operation: "account") }
        try await transport.waitForCalls(2)
        await transport.complete(1, .success(.string("account-B")))
        await new.value
        await transport.complete(0, .failure(NativeFailure(code: "ACCOUNT_A", message: "old failure")))
        await old.value
        #expect(state.value == .string("account-B"))
        #expect(state.failure == nil)
        state.invalidate()
        #expect(state.value == nil)
        #expect(!state.isLoading)
    }

    @Test @MainActor func cancellationIsNotPresentedAsLoadFailure() async throws {
        let bridge = SyntheticBridge()
        let state = NativeRequestState()
        let task = Task { await state.load(using: bridge.transport, operation: "account") }
        try await eventually { bridge.calls.count == 1 }
        task.cancel()
        await task.value
        #expect(!state.isLoading)
        #expect(state.failure == nil)
        #expect(bridge.cancellations.value == 1)
    }
}
