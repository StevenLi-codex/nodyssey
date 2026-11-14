import Foundation
import NodysseyNativeCore
import NodysseyShell

/// Kotlin callback adapter. The new termination selector still requires the
/// generated-header / full-Xcode integration gate documented in swiftui-request-drain.md.
struct NativeClient: NativeTransport {
    private let adapter: CallbackNativeTransport
    init() {
        adapter = CallbackNativeTransport(drainingRequest: { operation, arguments, completion, terminated in
            let request = NativeBridge.shared.request(operation: operation, argumentsJson: arguments, completion: completion)
            // Job completion, not JSON delivery or cancel(), owns the file lease.
            // Register before handle installation; registration after completion is supported.
            request.invokeOnCompletion(completion: terminated)
            let handle = NativeBridgeHandle(request)
            return NativeCancellation { Task { @MainActor in handle.cancel() } }
        }, observe: { operation, arguments, completion in
            let handle = NativeBridgeHandle(NativeBridge.shared.observe(operation: operation, argumentsJson: arguments, completion: completion))
            return NativeCancellation { Task { @MainActor in handle.cancel() } }
        })
    }
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await adapter.request(operation, arguments)
    }
    func request(_ operation: String, _ arguments: [String: JSONValue], onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue {
        try await adapter.request(operation, arguments, onTermination: onTermination)
    }
    func observe(_ operation: String, _ arguments: [String: JSONValue] = [:]) -> AsyncThrowingStream<JSONValue, Error> {
        adapter.observe(operation, arguments)
    }
}

@MainActor private final class NativeBridgeHandle {
    private var handle: NativeRequest?
    init(_ handle: NativeRequest) { self.handle = handle }
    func cancel() { handle?.cancel(); handle = nil }
}

extension NativeAppModel {
    convenience init() { self.init(transport: NativeClient()) }
}
