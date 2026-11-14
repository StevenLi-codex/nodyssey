import Foundation
import Testing
import NodysseyNativeCore
@testable import NativeLibrary

@MainActor @Test func partialDeleteKeepsFailedIDsAndUndoRetriesOnlySuccesses() async throws {
    var calls: [Int64] = []
    let result = try await LibraryOperations.collect([1, 2, 9_007_199_254_740_993], collected: false) { op, args in
        if op == "bookmarks.snapshot" { return .array([.object(["postId": .integer(2)])]) }
        let id = try JSONValue.object(args).requireInt("postId")
        calls.append(id)
        if id == 2 { throw NativeFailure(code: "NETWORK", message: "") }
        return .null
    }
    #expect(result.succeeded == [1, 9_007_199_254_740_993])
    #expect(Set(result.failures.keys) == [2])
    #expect(calls == [1, 2, 9_007_199_254_740_993])
}

@MainActor @Test func collectionEchoMustMatchRequestedStateBeforeOfferingUndo() async throws {
    let outcome = try await LibraryOperations.collect([99], collected: false) { op, _ in
        if op == "bookmarks.snapshot" { return .array([.object(["postId": .integer(99)])]) }
        return .null
    }
    #expect(outcome.succeeded.isEmpty)
    #expect(outcome.failures[99]?.code == "NOT_CONFIRMED")
}

@MainActor @Test func cancelledBatchRetainsUndoForAlreadyConfirmedRemoval() async {
    var progress = LibraryBatchResult()
    do {
        _ = try await LibraryOperations.collect([1, 2], collected: false, progress: { progress = $0 }) { op, args in
            if args["postId"]?.int == 2 { throw CancellationError() }
            return op == "bookmarks.snapshot" ? .array([]) : .null
        }
    } catch {}
    #expect(progress.succeeded == [1])
}

@MainActor @Test func cancellationStopsBulkMutationWithoutRetrying() async {
    var count = 0
    do {
        _ = try await LibraryOperations.collect([1, 2, 3], collected: false) { _, _ in
            count += 1
            throw CancellationError()
        }
        Issue.record("Cancellation must propagate")
    } catch is CancellationError {} catch { Issue.record("Wrong failure") }
    #expect(count == 1)
}
