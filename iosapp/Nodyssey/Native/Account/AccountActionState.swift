import Foundation
import Combine
import NodysseyNativeCore

/// The actual screen coordinator; injected closures keep its lifecycle behavior testable.
@MainActor
final class AccountAction: ObservableObject {
    @Published var state = AccountMutationState()
    @Published var failure: NativeFailure?
    @Published private(set) var isRefreshing = false
    private var isCurrent: (() -> Bool)?
    private var task: Task<Void, Never>?
    private var readBack: (() async throws -> Void)?
    var blocked: Bool { state.blocksWrite || isRefreshing }
    var canRefresh: Bool {
        [.uncertain, .savedNeedsRefresh].contains(state.phase) && !isRefreshing && readBack != nil && isCurrent?() == true
    }

    func perform(operation: String, arguments: [String: JSONValue],
                 request: @escaping (String, [String: JSONValue]) async throws -> JSONValue,
                 currentGeneration: @escaping () -> Int,
                 read: @escaping () async throws -> Void, received: @escaping (JSONValue) -> Void = { _ in }) {
        let observableOutcome = !["account.changePassword", "account.beginTwoFactor"].contains(operation)
        guard let ticket = state.begin(confirmed: true, readbackCanResolveUncertainty: observableOutcome) else { return }
        // Only failures caught here are proven pre-write. Never infer that a generic
        // bridge/server INVALID_ARGUMENT, AUTH_REQUIRED or INTERNAL means no write.
        if operation == "keywords.add" {
            let text = arguments["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pattern = String(decoding: text.utf16.prefix(200), as: UTF16.self)
            if text.isEmpty || (arguments["kind"] == .string("BLOCK_REGEX") && (try? NSRegularExpression(pattern: pattern)) == nil) {
                state.rejectBeforeWrite(ticket)
                failure = NativeFailure(code: "INVALID_ARGUMENT", message: "")
                readBack = nil
                return
            }
        }
        let generation = currentGeneration()
        isCurrent = { currentGeneration() == generation }
        failure = nil; readBack = read
        task = Task {
            do {
                let result = try await request(operation, arguments)
                guard !Task.isCancelled, currentGeneration() == generation, state.ticket == ticket else { return }
                state.acknowledge(ticket)
                received(result)
                do {
                    try await read()
                    guard !Task.isCancelled, currentGeneration() == generation else { return }
                    state.refreshed(ticket)
                } catch {
                    guard !Task.isCancelled, currentGeneration() == generation else { return }
                    state.readFailed(ticket); failure = accountFailure(error)
                }
            } catch {
                guard !Task.isCancelled, currentGeneration() == generation else { return }
                state.writeFailed(ticket); failure = accountFailure(error)
            }
        }
    }
    func refreshOnly() {
        guard canRefresh, let ticket = state.ticket, let readBack, let isCurrent else { return }
        isRefreshing = true
        task = Task {
            defer { if state.ticket == ticket { isRefreshing = false } }
            do {
                guard isCurrent() else { return }
                try await readBack()
                guard !Task.isCancelled, isCurrent(), state.ticket == ticket else { return }
                state.refreshed(ticket); failure = nil
            } catch {
                guard !Task.isCancelled, isCurrent(), state.ticket == ticket else { return }
                failure = accountFailure(error)
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; readBack = nil; isCurrent = nil
        isRefreshing = false; state.invalidate(); failure = nil
    }
}

func accountFailure(_ error: Error) -> NativeFailure {
    NativeFailure(code: (error as? NativeFailure)?.code ?? "INTERNAL", message: "")
}
