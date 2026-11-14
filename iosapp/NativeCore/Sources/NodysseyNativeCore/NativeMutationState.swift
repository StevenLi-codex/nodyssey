import Foundation

/// One instance per composer: share this gate across publish/send buttons.
/// Cancellation cannot undo a server mutation; no automatic retry is performed.
@MainActor public final class NativeMutationState {
    public var draft: String { didSet { if oldValue != draft { draftRevision = UUID() } } }
    private var draftRevision = UUID()
    public private(set) var isSubmitting = false
    public private(set) var failure: NativeFailure?
    private var generation = UUID()
    private var task: Task<JSONValue, Error>?

    public init(draft: String = "") { self.draft = draft }

    @discardableResult
    public func submit(using transport: any NativeTransport, operation: String,
                       arguments: [String: JSONValue] = [:], draftKey: String) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !isSubmitting else {
            throw NativeFailure(code: "IN_FLIGHT", message: "A submission is already in progress")
        }
        let token = generation
        let submittedDraft = draft
        let submittedRevision = draftRevision
        var payload = arguments
        payload[draftKey] = .string(submittedDraft)
        isSubmitting = true
        failure = nil
        let pending = Task { try await transport.request(operation, payload) }
        task = pending
        let result = await withTaskCancellationHandler { await pending.result } onCancel: { pending.cancel() }
        guard token == generation else { throw CancellationError() }
        isSubmitting = false
        task = nil
        try Task.checkCancellation()
        guard !pending.isCancelled else { throw CancellationError() }
        switch result {
        case .success(let value):
            if draftRevision == submittedRevision { draft = "" }
            return value
        case .failure(let error):
            if error is CancellationError { throw error }
            let failure = error as? NativeFailure ?? NativeFailure(code: "TRANSPORT", message: "Submission failed")
            self.failure = failure
            throw failure
        }
    }

    /// Account/site transition: erase transient sensitive input and fence late completions.
    public func invalidate() {
        generation = UUID()
        task?.cancel()
        task = nil
        isSubmitting = false
        failure = nil
        draft = ""
    }
}
