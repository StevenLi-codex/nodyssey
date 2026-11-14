import Foundation
import NodysseyNativeCore
import NodysseyShell

/// Selectors checked against the generated NodysseyShell.h, not a parallel repository.
struct NativeClient: NativeTransport {
    private let adapter: CallbackNativeTransport
    init() {
        adapter = CallbackNativeTransport(request: { operation, arguments, completion in
            let handle = NativeBridgeHandle(NativeBridge.shared.request(operation: operation, argumentsJson: arguments, completion: completion))
            return NativeCancellation { Task { @MainActor in handle.cancel() } }
        }, observe: { operation, arguments, completion in
            let handle = NativeBridgeHandle(NativeBridge.shared.observe(operation: operation, argumentsJson: arguments, completion: completion))
            return NativeCancellation { Task { @MainActor in handle.cancel() } }
        })
    }
    func request(_ operation: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await adapter.request(operation, arguments)
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
