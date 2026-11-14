import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeFoundation

final class ControlledTransport: NativeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); pending[operation] = continuation; lock.unlock()
        }
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            lock.lock(); streams[operation] = continuation; lock.unlock()
        }
    }
    func hasRequest(_ operation: String) -> Bool { lock.lock(); defer { lock.unlock() }; return pending[operation] != nil }
    func hasStream(_ operation: String) -> Bool { lock.lock(); defer { lock.unlock() }; return streams[operation] != nil }
    func resolve(_ operation: String, _ result: Result<JSONValue, Error>) {
        lock.lock(); let continuation = pending.removeValue(forKey: operation); lock.unlock()
        continuation?.resume(with: result)
    }
    func emit(_ operation: String, _ value: JSONValue) {
        lock.lock(); let stream = streams[operation]; lock.unlock(); stream?.yield(value)
    }
    func finish(_ operation: String, error: Error? = nil) {
        lock.lock(); let stream = streams.removeValue(forKey: operation); lock.unlock(); stream?.finish(throwing: error)
    }
}

@MainActor func eventually(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NativeFailure(code: "TEST_TIMEOUT", message: "Condition never became true")
}

@Suite @MainActor struct StoreTests {
    @Test func endedObservationWithoutDataIsFailureNotEmptySuccess() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let task = Task { await store.observe(app, "empty") }
        try await eventually { transport.hasStream("empty") }
        transport.finish("empty")
        await task.value
        #expect(store.failure?.code == "OBSERVATION_ENDED")
        #expect(!store.isLoading)
    }
    @Test func nullEmissionClearsPrivateContentAndCancellationDoesNotBecomeFailure() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let task = Task { await store.observe(app, "profile.self") }
        try await eventually { transport.hasStream("profile.self") }
        transport.emit("profile.self", .string("private"))
        try await eventually { store.value == .string("private") }
        transport.emit("profile.self", .null)
        try await eventually { store.value == .null }
        task.cancel()
        await task.value
        #expect(store.failure == nil)
        #expect(!store.isLoading)
    }
    @Test func accountChangeClearsMountedStoreBeforeLateReply() async throws {
        let transport = ControlledTransport()
        let app = NativeAppModel(transport: transport)
        let store = NativeStore()
        let old = Task { await store.load(app, "old") }
        try await eventually { transport.hasRequest("old") }
        transport.resolve("old", .success(.string("private old account")))
        await old.value
        #expect(store.value == .string("private old account"))
        let late = Task { await store.load(app, "late") }
        try await eventually { transport.hasRequest("late") }
        app.session = .object(["isSignedIn": .bool(false), "generation": .integer(2)])
        #expect(store.value == .null)
        transport.resolve("late", .success(.string("private late response")))
        await late.value
        #expect(store.value == .null)
        #expect(!store.isLoading)
        #expect(store.failure == nil)
    }
}
