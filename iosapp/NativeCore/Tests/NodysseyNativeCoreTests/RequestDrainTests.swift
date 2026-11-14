import Foundation
import Testing
@testable import NodysseyNativeCore

@MainActor private final class DrainBridge {
    var result: (@Sendable (String) -> Void)?
    var terminate: (@Sendable () -> Void)?
    var started: CheckedContinuation<Void, Never>?
    var duringStart: (() -> Void)?
    let cancelled = CancellationCounter()
    var transport: CallbackNativeTransport {
        CallbackNativeTransport(drainingRequest: { [self] _, _, result, terminate in
            self.result = result
            self.terminate = terminate
            duringStart?() // can cancel before the platform handle is installed
            started?.resume(); started = nil
            return NativeCancellation { [cancelled] in cancelled.increment() }
        }, observe: { _, _, _ in NativeCancellation {} })
    }
    func waitForStart() async {
        if result != nil { return }
        await withCheckedContinuation { started = $0 }
    }
}

@Suite(.timeLimit(.minutes(1))) struct RequestDrainTests {
    @Test @MainActor func resultCallbackBeforeFinallyDoesNotAcknowledgeTermination() async throws {
        let bridge = DrainBridge(), drained = CancellationCounter()
        let request = Task { try await bridge.transport.request("upload", [:], onTermination: { drained.increment() }) }
        await bridge.waitForStart()
        bridge.result?(#"{"ok":true,"data":7}"#)
        #expect(try await request.value == .integer(7))
        #expect(drained.value == 0)
        bridge.terminate?()
        bridge.terminate?()
        #expect(drained.value == 1)
    }

    @Test @MainActor func cancellationBeforeHandleInstallationDoesNotDrainReader() async throws {
        let bridge = DrainBridge(), drained = CancellationCounter()
        var request: Task<JSONValue, Error>!
        bridge.duringStart = { request.cancel() }
        request = Task { try await bridge.transport.request("upload", [:], onTermination: { drained.increment() }) }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(bridge.cancelled.value == 1)
        #expect(drained.value == 0)
        bridge.result?(#"{"ok":true,"data":"late"}"#)
        #expect(drained.value == 0)
        bridge.terminate?()
        #expect(drained.value == 1)
        bridge.duringStart = nil
    }

    @Test @MainActor func cancellationBeforeDispatchReleasesUnusedLease() async throws {
        let bridge = DrainBridge(), drained = CancellationCounter()
        let request = Task { try await bridge.transport.request("upload", [:], onTermination: { drained.increment() }) }
        request.cancel() // this actor has not yielded, so start cannot have run
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(bridge.result == nil)
        #expect(bridge.cancelled.value == 0)
        #expect(drained.value == 1)
    }

    @Test @MainActor func synchronousCompletionBeforeHandleInstallStillWaitsForDrain() async throws {
        let bridge = DrainBridge(), drained = CancellationCounter()
        bridge.duringStart = { bridge.result?(#"{"ok":true,"data":null}"#) }
        #expect(try await bridge.transport.request("upload", [:], onTermination: { drained.increment() }) == .null)
        #expect(bridge.cancelled.value == 1)
        #expect(drained.value == 0)
        bridge.terminate?()
        #expect(drained.value == 1)
        bridge.duringStart = nil
    }

    @Test @MainActor func failureResultDoesNotAcknowledgeTermination() async throws {
        let bridge = DrainBridge(), drained = CancellationCounter()
        let request = Task { try await bridge.transport.request("upload", [:], onTermination: { drained.increment() }) }
        await bridge.waitForStart()
        bridge.result?(#"{"ok":false,"error":{"code":"INTERNAL","message":"failed"}}"#)
        await #expect(throws: NativeFailure.self) { try await request.value }
        #expect(drained.value == 0)
        bridge.terminate?()
        #expect(drained.value == 1)
    }
}
