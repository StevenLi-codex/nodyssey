import Foundation

/// Transient screen state. Invalidate before exposing a changed account or site.
@MainActor public final class NativeRequestState {
    public private(set) var value: JSONValue?
    public private(set) var failure: NativeFailure?
    public private(set) var isLoading = false
    /// Called after state changes. Capture UI owners weakly to avoid retaining them.
    public var onChange: (@MainActor () -> Void)?
    private var generation = UUID()
    private var requestTask: Task<JSONValue, Error>?
    private var observationTask: Task<Void, Never>?

    public init() {}

    public func load(using transport: any NativeTransport, operation: String, arguments: [String: JSONValue] = [:]) async {
        cancel()
        let token = generation
        isLoading = true
        failure = nil
        onChange?()
        let task = Task { try await transport.request(operation, arguments) }
        requestTask = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        guard token == generation else { return }
        requestTask = nil
        isLoading = false
        defer { onChange?() }
        guard !Task.isCancelled, !task.isCancelled else { return }
        switch result {
        case .success(let data): value = data
        case .failure(let error):
            if !(error is CancellationError) {
                failure = error as? NativeFailure ?? NativeFailure(code: "TRANSPORT", message: "Request failed")
            }
        }
    }

    public func observe(using transport: any NativeTransport, operation: String, arguments: [String: JSONValue] = [:]) async {
        cancel()
        let token = generation
        isLoading = true
        failure = nil
        onChange?()
        let task = Task { [weak self] in
            do {
                for try await data in transport.observe(operation, arguments) {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    self.value = data
                    self.isLoading = false
                    self.onChange?()
                }
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                if !(error is CancellationError) {
                    self.failure = error as? NativeFailure ?? NativeFailure(code: "TRANSPORT", message: "Observation failed")
                }
            }
        }
        observationTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard generation == token else { return }
        observationTask = nil
        isLoading = false
        onChange?()
    }

    public func cancel() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        observationTask?.cancel()
        observationTask = nil
        isLoading = false
        onChange?()
    }

    public func invalidate() {
        value = nil
        failure = nil
        cancel()
    }
}
