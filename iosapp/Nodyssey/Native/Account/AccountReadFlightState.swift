import Foundation
import Combine

/// One real read per full request key; stale and cancelled work cannot publish.
@MainActor final class AccountReadFlightState: ObservableObject {
    @Published private(set) var isLoading = false
    private var flight: (key: String, token: UUID, task: Task<Bool, Never>)?

    func run(key: String, current: @escaping @MainActor () -> Bool,
             work: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Bool) async -> Bool {
        guard !Task.isCancelled, current() else { return false }
        if let flight, flight.key == key {
            let result = await flight.task.value
            return !Task.isCancelled && current() && result
        }
        cancel()
        let token = UUID()
        isLoading = true
        let task = Task { @MainActor [weak self] in
            let accepted = { @MainActor [weak self] in
                self?.flight?.token == token && current() && !Task.isCancelled
            }
            defer { if self?.flight?.token == token { self?.flight = nil; self?.isLoading = false } }
            guard accepted() else { return false }
            let result = await work(accepted)
            return accepted() && result
        }
        flight = (key, token, task)
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in if self?.flight?.token == token { self?.cancel() } }
        }
        return !Task.isCancelled && current() && result
    }

    func cancel() {
        flight?.task.cancel(); flight = nil; isLoading = false
    }
}
