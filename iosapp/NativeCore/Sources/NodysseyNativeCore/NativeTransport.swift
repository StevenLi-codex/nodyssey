import Foundation

public protocol NativeTransport: Sendable {
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue
    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error>
    /// Independent of result delivery/cancellation; acknowledges actual consumer termination.
    func request(_ operation: String, _ arguments: [String: JSONValue], onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue
}

public extension NativeTransport {
    /// Legacy adapters cannot prove drain. Deliberately retain leased resources,
    /// even when their Swift continuation returns; never manufacture an acknowledgement.
    func request(_ operation: String, _ arguments: [String: JSONValue], onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue {
        try await request(operation, arguments)
    }
}

/// Idempotent and thread-safe. Platform closures must hop to MainActor if their handle requires it.
public final class NativeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    public init(_ action: @escaping @Sendable () -> Void) { self.action = action }

    public func cancel() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// Adapts the real Kotlin callback ABI without importing Kotlin, UIKit, or SwiftUI.
public struct CallbackNativeTransport: NativeTransport {
    public typealias Start = @MainActor @Sendable (String, String, @escaping @Sendable (String) -> Void) -> NativeCancellation
    public typealias DrainingStart = @MainActor @Sendable (String, String, @escaping @Sendable (String) -> Void, @escaping @Sendable () -> Void) -> NativeCancellation
    private let requestStart: DrainingStart
    private let observeStart: Start

    public init(request: @escaping Start, observe: @escaping Start) {
        requestStart = { operation, arguments, result, _ in request(operation, arguments, result) }
        observeStart = observe
    }

    public init(drainingRequest: @escaping DrainingStart, observe: @escaping Start) {
        requestStart = drainingRequest
        observeStart = observe
    }

    public func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await request(operation, arguments, onTermination: {})
    }

    public func request(_ operation: String, _ arguments: [String: JSONValue], onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue {
        let termination = RequestTermination(onTermination)
        let json: String
        do {
            try Task.checkCancellation()
            json = String(decoding: try JSONEncoder().encode(JSONValue.object(arguments)), as: UTF8.self)
        } catch {
            termination.signal() // No platform consumer was dispatched.
            throw error
        }
        let pending = PendingRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                Task { @MainActor in
                    guard pending.isPending else { termination.signal(); return }
                    let handle = requestStart(operation, json, { response in
                        pending.finish(Result { try NativeEnvelope.decode(response) })
                    }, { termination.signal() })
                    pending.lifetime.install(handle)
                }
            }
        } onCancel: {
            // UI result cancellation is intentionally immediate. It does not
            // establish that the Kotlin reader or its finally blocks stopped.
            pending.finish(.failure(CancellationError()))
        }
    }

    public func observe(_ operation: String, _ arguments: [String: JSONValue] = [:]) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let lifetime = OperationLifetime()
            continuation.onTermination = { _ in lifetime.cancel() }
            Task { @MainActor in
                do {
                    guard !lifetime.isCancelled else { return }
                    let json = String(decoding: try JSONEncoder().encode(JSONValue.object(arguments)), as: UTF8.self)
                    let handle = observeStart(operation, json) { response in
                        guard !lifetime.isCancelled else { return }
                        do { continuation.yield(try NativeEnvelope.decode(response)) }
                        catch { continuation.finish(throwing: error); lifetime.cancel() }
                    }
                    lifetime.install(handle)
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

/// Kept independently of PendingRequest: a result callback may precede finally.
private final class RequestTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    func signal() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }
}

/// Handles cancellation/completion before the platform start call returns its handle.
private final class OperationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: NativeCancellation?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func install(_ handle: NativeCancellation) {
        lock.lock()
        let cancelNow = cancelled
        if !cancelNow { self.handle = handle }
        lock.unlock()
        if cancelNow { handle.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handle = self.handle
        self.handle = nil
        lock.unlock()
        handle?.cancel()
    }
}

private final class PendingRequest: @unchecked Sendable {
    let lifetime = OperationLifetime()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var result: Result<JSONValue, Error>?
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }

    func install(_ continuation: CheckedContinuation<JSONValue, Error>) {
        lock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<JSONValue, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        lifetime.cancel()
        continuation?.resume(with: result)
    }
}
