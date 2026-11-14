import Foundation
import Combine
import NodysseyNativeCore

/// One operation per store. The core owns cancellation and stale-operation suppression.
@MainActor final class NativeStore: ObservableObject {
    @Published var value: JSONValue = .null
    @Published var failure: NativeFailure?
    @Published var isLoading = false
    private let state = NativeRequestState()
    private var operation = UUID()

    init() {
        state.onChange = { [weak self] in
            guard let self else { return }
            self.value = self.state.value ?? .null
            self.failure = self.state.failure
            self.isLoading = self.state.isLoading
        }
    }
    func load(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async {
        self.operation = UUID()
        app.register(self)
        await state.load(using: app.transport, operation: operation, arguments: arguments)
    }
    func observe(_ app: NativeAppModel, _ operation: String, _ arguments: [String: JSONValue] = [:]) async {
        let token = UUID()
        self.operation = token
        app.register(self)
        await state.observe(using: app.transport, operation: operation, arguments: arguments)
        if self.operation == token, !Task.isCancelled, failure == nil {
            failure = NativeFailure(code: "OBSERVATION_ENDED", message: "Observation ended")
        }
    }
    func invalidate() { operation = UUID(); state.invalidate() }
}
