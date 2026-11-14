import Foundation
import Combine
import NodysseyNativeCore

struct AccountPendingWrite {
    let operation: String
    let arguments: [String: JSONValue]
    let inputRevision: UUID?
    init(_ operation: String, _ arguments: [String: JSONValue], inputRevision: UUID? = nil) {
        self.operation = operation
        self.arguments = arguments
        self.inputRevision = inputRevision
    }
}

/// The block screen's input and keyword action wiring, shared with behavioral tests.
@MainActor
final class AccountKeywordDraft: ObservableObject {
    @Published var text = "" { didSet { revision = UUID() } }
    @Published var regex = false { didSet { revision = UUID() } }
    private var revision = UUID()
    var kind: String { regex ? "BLOCK_REGEX" : "BLOCK" }

    func add() -> AccountPendingWrite {
        AccountPendingWrite("keywords.add", ["kind": .string(kind), "text": .string(text)], inputRevision: revision)
    }

    func perform(_ write: AccountPendingWrite, action: AccountAction,
                 request: @escaping (String, [String: JSONValue]) async throws -> JSONValue,
                 currentGeneration: @escaping () -> Int,
                 publish: @escaping (JSONValue) -> Void) {
        let generation = currentGeneration()
        action.perform(operation: write.operation, arguments: write.arguments, request: request,
                       currentGeneration: currentGeneration, read: {
            let value = try await request("keywords.get", ["kind": write.arguments["kind"]!])
            guard !Task.isCancelled, currentGeneration() == generation else { return }
            if write.arguments["kind"] == .string(self.kind) { publish(value) }
        }, received: { _ in
            // Only an acknowledged add may consume its captured input. Read-only
            // recovery never calls this, and A -> B -> A is still a new draft.
            guard write.operation == "keywords.add", write.inputRevision == self.revision,
                  write.arguments["kind"] == .string(self.kind) else { return }
            self.text = ""
        })
    }
}
