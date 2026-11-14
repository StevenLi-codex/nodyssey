import Foundation
import NodysseyNativeCore

typealias LibraryRequest = @MainActor (String, [String: JSONValue]) async throws -> JSONValue

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
}

struct LibraryPaymentOutcome {
    var acknowledged = false
    var writeFailure: NativeFailure?
    var refreshFailure: NativeFailure?
    var ledger: JSONValue = .null
    var growth: JSONValue = .null
}

extension LibraryOperations {
    @MainActor static func pay(_ payment: LibraryPayment, confirmed: Bool, request: LibraryRequest) async throws -> LibraryPaymentOutcome {
        guard confirmed else { throw NativeFailure(code: "CONFIRMATION_REQUIRED", message: "") }
        var outcome = LibraryPaymentOutcome()
        var arguments = payment.arguments
        arguments["confirmed"] = .bool(true)
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
            outcome.growth = try await request("assets.growth", [:])
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
