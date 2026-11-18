import Foundation
import NodysseyNativeCore

/// Page identity belongs to the pager, not its viewport or earliest cached row.
enum ContentFeedTopRefresh {
    enum Plan: Equatable {
        case refresh(scroll: Int64?)
        case replace
    }
    static func plan(_ snapshot: JSONValue, atTop: Bool) throws -> Plan {
        let window = try ContentPagingWindow(snapshot)
        guard snapshot["page"]?.int == 1,
              snapshot["refresh"]?["status"]?.string != "Error" else { return .replace }
        // A page-one pager can have evicted its first source page. Refresh still
        // starts at one; do not replace it (initialize may otherwise duplicate IO).
        let first = window.rows.first.flatMap { $0.page == 1 ? $0.id : nil }
        return .refresh(scroll: atTop ? nil : first)
    }
}

/// Registered before starting observation; never adds a second refresh request.
@MainActor final class ContentFeedTopRefreshFlight {
    private struct Flight {
        let id: UUID
        let owner: ContentFeedTicket
        let pager: String
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    private var flight: Flight?
    private var watchdog: Task<Void, Never>?
    var pending: Bool { flight != nil }

    func wait(owner: ContentFeedTicket, pager: String, timeout: TimeInterval = 30,
              start: () -> Void) async -> Bool {
        guard !Task.isCancelled else { return false }
        let waiter = UUID()
        let existing = flight != nil
        if let flight, flight.owner != owner || flight.pager != pager { return false }
        if flight == nil { flight = Flight(id: UUID(), owner: owner, pager: pager) }
        let id = flight!.id
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                flight?.waiters[waiter] = continuation
                if !existing {
                    watchdog = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(max(0.001, min(timeout, 86_400)) * 1_000_000_000)) }
                        catch { return }
                        guard self?.flight?.id == id else { return }
                        self?.cancel()
                    }
                    start()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flight?.id == id else { return }
                self?.flight?.waiters.removeValue(forKey: waiter)?.resume(returning: false)
            }
        }
        return result && !Task.isCancelled
    }

    func update(_ snapshot: JSONValue, current: ContentFeedTicket, failed: Bool = false) {
        guard let flight else { return }
        guard current == flight.owner, !failed else { cancel(); return }
        guard snapshot["pagerId"]?.string == flight.pager, snapshot["page"]?.int == 1 else { return }
        switch snapshot["refresh"]?["status"]?.string {
        case "Error": cancel()
        case "NotLoading":
            // Cached source terminals are not evidence of this forced remote read.
            guard snapshot["remoteRefreshComplete"]?.bool == true else { return }
            guard let window = try? ContentPagingWindow(snapshot), window.rows.isEmpty || window.rows.first?.page == 1 else { return }
            resolve(true)
        default: break
        }
    }
    func cancel() { resolve(false) }
    private func resolve(_ result: Bool) {
        guard let flight else { return }
        self.flight = nil
        watchdog?.cancel(); watchdog = nil
        for waiter in flight.waiters.values { waiter.resume(returning: result) }
    }
}
