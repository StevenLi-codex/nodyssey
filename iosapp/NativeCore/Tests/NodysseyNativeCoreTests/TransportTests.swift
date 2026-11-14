import Foundation
import Testing
@testable import NodysseyNativeCore

/// Synthetic ABI only: no Kotlin, real account, or network is involved.
@MainActor final class SyntheticBridge {
    var callbacks: [@Sendable (String) -> Void] = []
    var calls: [(String, String)] = []
    let cancellations = CancellationCounter()
    func start(_ operation: String, _ arguments: String, _ callback: @escaping @Sendable (String) -> Void) -> NativeCancellation {
        calls.append((operation, arguments))
        callbacks.append(callback)
        let counter = cancellations
        return NativeCancellation { counter.increment() }
    }
    var transport: CallbackNativeTransport {
        CallbackNativeTransport(request: { [self] in start($0, $1, $2) }, observe: { [self] in start($0, $1, $2) })
    }
}

final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<2000 {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NativeFailure(code: "TEST_TIMEOUT", message: "Synthetic operation did not progress")
}

struct TransportTests {
    @Test @MainActor func observationDeliversValuesThenFailureReleasesHandle() async throws {
        let bridge = SyntheticBridge()
        var received: [JSONValue] = []
        let task = Task {
            for try await value in bridge.transport.observe("session", [:]) { received.append(value) }
        }
        try await eventually { bridge.calls.count == 1 }
        bridge.callbacks[0](#"{"ok":true,"data":1}"#)
        bridge.callbacks[0](#"{"ok":true,"data":2}"#)
        try await eventually { received.count == 2 }
        bridge.callbacks[0](#"{"ok":false,"error":{"code":"SIGNED_OUT","message":"Session ended"}}"#)
        await #expect(throws: NativeFailure(code: "SIGNED_OUT", message: "Session ended")) { try await task.value }
        bridge.callbacks[0](#"{"ok":true,"data":3}"#)
        #expect(received == [.integer(1), .integer(2)])
        #expect(bridge.cancellations.value == 1)
    }

    @Test @MainActor func cancelledObserverReleasesHandleWithoutServerCallback() async throws {
        let bridge = SyntheticBridge()
        let task = Task { for try await _ in bridge.transport.observe("session", [:]) {} }
        try await eventually { bridge.calls.count == 1 }
        task.cancel()
        _ = await task.result
        #expect(bridge.cancellations.value == 1)
    }

    @Test @MainActor func requestDecodesEnvelopeAndIgnoresDuplicateCallbacks() async throws {
        let bridge = SyntheticBridge()
        let task = Task { try await bridge.transport.request("post", ["id": .integer(9007199254740993)]) }
        try await eventually { bridge.calls.count == 1 }
        let encoded = try JSONDecoder().decode(JSONValue.self, from: Data(bridge.calls[0].1.utf8))
        #expect(encoded["id"]?.int == 9007199254740993)
        bridge.callbacks[0](#"{"ok":true,"data":{"id":9223372036854775807}}"#)
        bridge.callbacks[0](#"{"ok":false,"error":{"code":"LATE","message":"late"}}"#)
        #expect(try await task.value["id"]?.int == Int64.max)
    }

    @Test @MainActor func requestCancellationResumesWithoutCallbackAndCancelsHandleOnce() async throws {
        let bridge = SyntheticBridge()
        let task = Task { try await bridge.transport.request("publish", [:]) }
        try await eventually { bridge.calls.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bridge.cancellations.value == 1)
        bridge.callbacks[0](#"{"ok":true,"data":"too late"}"#)
        task.cancel()
        #expect(bridge.cancellations.value == 1)
    }
}
