import Foundation
import Combine
import NodysseyNativeCore

typealias LibraryRequest = @MainActor (String, [String: JSONValue]) async throws -> JSONValue

/// Read-only publication lifetime, independent of an observing store's subscription.
@MainActor final class LibraryRefreshReadState: ObservableObject {
    @Published private(set) var isLoading = false
    private var flight: (key: String, token: UUID, task: Task<Bool, Never>)?

    static func read(current: @escaping @MainActor () -> Bool,
                     request: @MainActor () async throws -> JSONValue,
                     publish: @MainActor (JSONValue) -> Void,
                     fail: @MainActor (NativeFailure) -> Void) async -> Bool {
        guard !Task.isCancelled, current() else { return false }
        do {
            let value = try await request()
            guard !Task.isCancelled, current() else { return false }
            publish(value); return true
        } catch {
            guard !Task.isCancelled, current(), !(error is CancellationError) else { return false }
            fail((error as? NativeFailure) ?? NativeFailure(code: "INTERNAL", message: ""))
            return false
        }
    }

    func run(key: String, current: @escaping @MainActor () -> Bool,
             request: @escaping @MainActor () async throws -> JSONValue,
             publish: @escaping @MainActor (JSONValue) -> Void,
             fail: @escaping @MainActor (NativeFailure) -> Void) async -> Bool {
        guard !Task.isCancelled, current() else { return false }
        if let flight, flight.key == key {
            let result = await flight.task.value
            return !Task.isCancelled && current() && result
        }
        cancel()
        let token = UUID()
        isLoading = true
        let task = Task { @MainActor [weak self] in
            let result = await Self.read(current: { [weak self] in
                self?.flight?.token == token && current()
            }, request: request, publish: publish, fail: fail)
            if self?.flight?.token == token { self?.flight = nil; self?.isLoading = false }
            return result
        }
        flight = (key, token, task)
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in if self?.flight?.token == token { self?.cancel() } }
        }
        return !Task.isCancelled && current() && result
    }

    func cancel() { flight?.task.cancel(); flight = nil; isLoading = false }
}


struct LibraryBatchResult {
    var succeeded: Set<Int64> = []
    var failures: [Int64: NativeFailure] = [:]
}

enum LibraryOperations {
    @MainActor static func collect(_ ids: [Int64], collected: Bool, progress: @MainActor (LibraryBatchResult) -> Void = { _ in }, request: LibraryRequest) async throws -> LibraryBatchResult {
        var result = LibraryBatchResult()
        for id in Set(ids).sorted() {
            try Task.checkCancellation()
            do {
                _ = try await request("thread.collect", ["postId": .integer(id), "collected": .bool(collected)])
                let snapshot = try await request("bookmarks.snapshot", [:])
                guard let rows = snapshot.array else { throw NativeFailure(code: "INVALID_DATA", message: "") }
                let persisted = rows.contains { $0["postId"]?.int == id }
                guard persisted == collected else { throw NativeFailure(code: "NOT_CONFIRMED", message: "") }
                result.succeeded.insert(id)
            } catch is CancellationError { throw CancellationError() }
            catch let failure as NativeFailure {
                if failure.code == "SESSION_CHANGED" { throw failure }
                result.failures[id] = failure
            } catch { result.failures[id] = NativeFailure(code: "INTERNAL", message: "") }
            progress(result)
        }
        return result
    }
}

@MainActor final class LibraryHistoryUndo {
    private struct Receipt { let token: String; let expires: Date }
    private var receipts: [Receipt] = []
    private let clock: () -> Date
    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }
    var latest: String? { receipts.last(where: { $0.expires > clock() })?.token }
    func record(_ result: JSONValue) throws {
        guard let token = result["undoId"]?.string, !token.isEmpty else { throw NativeFailure(code: "INVALID_DATA", message: "") }
        receipts.removeAll { $0.expires <= clock() }
        receipts.append(Receipt(token: token, expires: clock().addingTimeInterval(300)))
        if receipts.count > 20 { receipts.removeFirst(receipts.count - 20) }
    }
    func reset() { receipts.removeAll() }
    func restore(request: LibraryRequest) async throws -> JSONValue {
        guard let token = latest else { throw NativeFailure(code: "INVALID_ARGUMENT", message: "") }
        _ = try await request("history.restore", ["undoId": .string(token)])
        // A successful one-shot restore consumes the handle even if the following refresh fails.
        receipts.removeAll { $0.token == token }
        return try await request("history.list", [:])
    }
}

struct LibraryPayment: Equatable {
    let recipient: Int64
    let amount: Int64
    let refId: Int64
    let onetime: Bool
    init(recipient: String, amount: String, refId: String, onetime: Bool) throws {
        guard let uid = Int64(recipient), uid > 0, let amount = Int64(amount), amount > 0,
              let ref = Int64(refId), ref >= 0 else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "")
        }
        self.recipient = uid; self.amount = amount; self.refId = ref; self.onetime = onetime
    }
    init(route: [String: JSONValue]) throws {
        guard let recipient = route["memberId"]?.int, let amount = route["amount"]?.int,
              let refId = route["refId"]?.int, let onetime = route["onetime"]?.bool else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "")
        }
        try self.init(recipient: String(recipient), amount: String(amount), refId: String(refId), onetime: onetime)
    }
    var arguments: [String: JSONValue] {
        ["recipientUid": .integer(recipient), "amount": .integer(amount), "refId": .integer(refId), "onetime": .bool(onetime)]
    }
    func shortfall(balance: Int64?) -> Int64? {
        guard let balance, balance < amount else { return nil }
        let difference = amount.subtractingReportingOverflow(balance)
        return difference.overflow ? Int64.max : difference.partialValue
    }
}

struct LibraryPaymentOutcome {
    var acknowledged = false
    /// A failure before the transfer request was dispatched. This is safe to retry.
    var preflightFailure: NativeFailure?
    /// True once the transfer request was handed to the transport. The result may
    /// still be unknown even when `writeFailure` is set.
    var writeAttempted = false
    var writeFailure: NativeFailure?
    var refreshFailure: NativeFailure?
    var ledger: JSONValue = .null
    var growth: JSONValue = .null
}

/// Route-owned payment recovery. Dismissing the sheet is safe while idle, but an
/// attempted payment keeps its exact intent fenced until an authoritative receipt
/// read says whether that intent was applied.
@MainActor final class LibraryPaymentRecovery: ObservableObject {
    @Published private(set) var frozenPayment: LibraryPayment?
    @Published private(set) var needsReadback = false
    @Published private(set) var paidPayment: LibraryPayment?
    @Published private(set) var isPaying = false
    private(set) var acknowledged = false

    func markWriteAttempted(_ payment: LibraryPayment) {
        frozenPayment = payment
        needsReadback = true
        paidPayment = nil
        acknowledged = false
    }

    func recordAcknowledgement(_ payment: LibraryPayment) {
        guard frozenPayment == payment else { return }
        acknowledged = true
    }

    func reconcile(_ payment: LibraryPayment, authoritativePaid: Bool) {
        // The caller may invoke this only after a complete, correlated receipt
        // read. A refreshed balance alone is not reconciliation authority.
        guard frozenPayment == payment, authoritativePaid else { return }
        needsReadback = false
        paidPayment = payment
    }

    func canDismiss(isBusy: Bool) -> Bool { !isBusy && !isPaying }

    func canPay(_ payment: LibraryPayment) -> Bool {
        !isPaying && !needsReadback && paidPayment != payment
    }

    func canLeaveRoute(isBusy: Bool) -> Bool { canDismiss(isBusy: isBusy) && !needsReadback }

    func pay(_ payment: LibraryPayment, request: LibraryRequest) async throws -> LibraryPaymentOutcome {
        guard canPay(payment) else { throw NativeFailure(code: "NOT_CONFIRMED", message: "") }
        isPaying = true
        defer { isPaying = false }
        let result = try await LibraryOperations.pay(payment, confirmed: true, willDispatch: {
            self.markWriteAttempted(payment)
        }, request: request)
        if result.acknowledged { recordAcknowledgement(payment) }
        return result
    }

    func reset() {
        frozenPayment = nil
        needsReadback = false
        paidPayment = nil
        acknowledged = false
    }
}

struct LibraryAttendanceOutcome {
    var acknowledged = false
    var writeFailure: NativeFailure?
    var refreshFailure: NativeFailure?
    var result: JSONValue = .null
    var status: JSONValue = .null
    var growth: JSONValue = .null
}

struct LibraryReceiptSummary {
    let all: [JSONValue]
    let mine: [JSONValue]
    var payerCount: Int { all.count }
    var received: Int64 { all.reduce(0) { $0 + max(0, $1["diff"]?.int ?? 0) } }
    var paidByMe: Bool { !mine.isEmpty }
}

extension LibraryOperations {
    @MainActor static func receipts(for payment: LibraryPayment, ownUID: Int64, request: LibraryRequest) async throws -> LibraryReceiptSummary {
        var arguments: [String: JSONValue] = ["memberId": .integer(payment.recipient), "refId": .integer(payment.refId)]
        let received = try await request("assets.receipts", arguments)
        try Task.checkCancellation()
        arguments["peerId"] = .integer(ownUID)
        let own = try await request("assets.receipts", arguments)
        guard let all = received.array, let mine = own.array else { throw NativeFailure(code: "INVALID_DATA", message: "") }
        return LibraryReceiptSummary(all: all, mine: mine)
    }

    @MainActor static func signAttendance(mode: String, request: LibraryRequest) async throws -> LibraryAttendanceOutcome {
        var outcome = LibraryAttendanceOutcome()
        do {
            outcome.result = try await request("attendance.sign", ["mode": .string(mode), "confirmed": .bool(true)])
            outcome.acknowledged = true
        } catch is CancellationError { throw CancellationError() }
        catch let failure as NativeFailure {
            if failure.code == "SESSION_CHANGED" { throw failure }
            outcome.writeFailure = failure
        } catch { outcome.writeFailure = NativeFailure(code: "INTERNAL", message: "") }
        do {
            outcome.status = try await request("attendance.status", [:])
            outcome.growth = try await refreshedGrowth(request: request)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as NativeFailure {
            if failure.code == "SESSION_CHANGED" { throw failure }
            outcome.refreshFailure = failure
        } catch { outcome.refreshFailure = NativeFailure(code: "INTERNAL", message: "") }
        return outcome
    }

    @MainActor static func refreshedGrowth(request: LibraryRequest) async throws -> JSONValue {
        // Growth reads the 60-second profile cache; a ledger read does not invalidate it.
        _ = try await request("profile.self", ["refresh": .bool(true)])
        try Task.checkCancellation()
        return try await request("assets.growth", [:])
    }

    @MainActor static func pay(_ payment: LibraryPayment, confirmed: Bool, willDispatch: @MainActor () -> Void = {}, request: LibraryRequest) async throws -> LibraryPaymentOutcome {
        guard confirmed else { throw NativeFailure(code: "CONFIRMATION_REQUIRED", message: "") }
        // Recheck immediately before spending as another device may have spent since review.
        // An absent balance is unknown, not zero; a failed read is not an attempted write.
        var outcome = LibraryPaymentOutcome()
        let profile: JSONValue
        do {
            profile = try await request("profile.self", ["refresh": .bool(true)])
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch let failure as NativeFailure {
            if failure.code == "SESSION_CHANGED" { throw failure }
            outcome.preflightFailure = failure
            return outcome
        } catch {
            outcome.preflightFailure = NativeFailure(code: "INTERNAL", message: "")
            return outcome
        }
        guard payment.shortfall(balance: profile["starCount"]?.int) == nil else {
            throw NativeFailure(code: "INSUFFICIENT_BALANCE", message: "")
        }
        var arguments = payment.arguments
        arguments["confirmed"] = .bool(true)
        outcome.writeAttempted = true
        willDispatch()
        do {
            _ = try await request("assets.transfer", arguments)
            outcome.acknowledged = true
        } catch is CancellationError { throw CancellationError() }
        catch let failure as NativeFailure {
            if failure.code == "SESSION_CHANGED" { throw failure }
            outcome.writeFailure = failure
        } catch { outcome.writeFailure = NativeFailure(code: "INTERNAL", message: "") }
        // Refresh on BOTH known success and indeterminate transport failure. Never repeat the write.
        do {
            outcome.ledger = try await request("assets.stardust", [:])
            outcome.growth = try await refreshedGrowth(request: request)
        } catch is CancellationError { throw CancellationError() }
        catch let failure as NativeFailure {
            if failure.code == "SESSION_CHANGED" { throw failure }
            outcome.refreshFailure = failure
        }
        catch { outcome.refreshFailure = NativeFailure(code: "INTERNAL", message: "") }
        return outcome
    }
}

struct LibraryReportSelection {
    private(set) var selected: [JSONValue] = []
    mutating func toggle(_ entry: JSONValue) {
        if let index = selected.firstIndex(of: entry) { selected.remove(at: index) }
        else if selected.count < 3 { selected.append(entry) }
    }
    func entries(in basket: [JSONValue]) throws -> [JSONValue] {
        let result = basket.filter { selected.contains($0) }
        guard (2...3).contains(result.count), result.count == selected.count else {
            throw NativeFailure(code: "INVALID_ARGUMENT", message: "")
        }
        return result
    }
}

enum LibraryRows {
    static func threadArguments(_ row: JSONValue) -> [String: JSONValue]? {
        guard let id = row["postId"]?.int, id > 0 else { return nil }
        var args: [String: JSONValue] = ["postId": .integer(id)]
        if let page = row["readingPosition"]?["page"]?.int, page > 0, page <= Int64(Int32.max) {
            args["page"] = .integer(page)
        }
        // Never merge arbitrary position keys over the actual post identity.
        let floor = row["floor"] ?? row["readingPosition"]?["floor"]
        if let text = floor?.string, !text.isEmpty { args["floor"] = .string(text) }
        return args
    }

    static func historyBucket(_ row: JSONValue, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let millis = row["lastReadAtMillis"]?.int else { return 3 }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 8
        switch days { case ...0: return 0; case 1: return 1; case 2...6: return 2; default: return 3 }
    }

    // NodeSeekSite's published paths, on the active origin from site.get, not the pending selection.
    static func communityURL(_ snapshot: JSONValue, path: String) -> String? {
        guard ["/providers", "/friends", "/about", "/lucky", "/ruling", "/rss.xml"].contains(path),
              let site = snapshot["sites"]?.array?.first(where: { $0["id"] == snapshot["current"] }),
              let origin = site["origin"]?.string, let url = URLComponents(string: origin),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty else { return nil }
        return origin + path
    }

    static func state(_ id: Int64, offline: JSONValue) -> JSONValue? {
        offline["states"]?.array?.first { $0["postId"]?.int == id }
    }
    static func visible(_ rows: [JSONValue], offline: JSONValue, query: String, filter: String, sort: String) -> [JSONValue] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = rows.filter { row in
            guard let id = row["postId"]?.int else { return false }
            let state = state(id, offline: offline)?["state"]?.string ?? "NotDownloaded"
            let matches = needle.isEmpty || ["title", "authorName"].contains { row[$0]?.string?.localizedCaseInsensitiveContains(needle) == true }
            return matches && (filter == "all" || (filter == "downloaded" && ["Downloaded", "Stale"].contains(state)) || (filter == "new" && state == "Stale"))
        }
        let ranks = ["NotDownloaded": 0, "Failed": 1, "Stale": 2, "Downloading": 3, "Downloaded": 4]
        return filtered.enumerated().sorted { left, right in
            if sort == "replies" {
                let a = left.element["commentCount"]?.int ?? -1, b = right.element["commentCount"]?.int ?? -1
                if a != b { return a > b }
            } else if sort == "pending" {
                let a = state(left.element["postId"]!.int!, offline: offline)?["state"]?.string ?? "NotDownloaded"
                let b = state(right.element["postId"]!.int!, offline: offline)?["state"]?.string ?? "NotDownloaded"
                if ranks[a] != ranks[b] { return (ranks[a] ?? 0) < (ranks[b] ?? 0) }
            }
            return left.offset < right.offset
        }.map(\.element)
    }
}

/// Transient selection; repository snapshots remain Kotlin-owned.
struct LibrarySelection {
    var selected: Set<Int64> = []
    var undoIDs: Set<Int64> = []

    mutating func selectVisible(_ ids: [Int64]) {
        let visible = Set(ids)
        if visible.isSubset(of: selected) { selected.subtract(visible) }
        else { selected.formUnion(visible) }
    }
    mutating func completeRemoval(succeeded: Set<Int64>, failed: Set<Int64>) {
        selected.subtract(succeeded)
        selected.formUnion(failed)
        undoIDs.formUnion(succeeded)
    }
}
