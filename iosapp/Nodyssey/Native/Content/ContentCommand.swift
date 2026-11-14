import Foundation
import Combine
import NodysseyNativeCore

/// The app supplies the session-guarded bridge; tests supply only a scripted boundary.
@MainActor protocol ContentCommandContext: AnyObject {
    var generation: Int { get }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue
}

/// Owns user-triggered work only. Observation lifetime belongs to SwiftUI .task.
@MainActor class ContentCommand: ObservableObject {
    @Published var failure: NativeFailure?
    @Published private(set) var busy = false
    private var task: Task<Void, Never>?
    @discardableResult
    func run(_ app: any ContentCommandContext, work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard !busy else { return nil }
        busy = true
        failure = nil
        let generation = app.generation
        let task = Task { @MainActor in
            defer { busy = false; self.task = nil }
            do {
                try Task.checkCancellation()
                guard generation == app.generation else { return }
                try await work()
            }
            catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == app.generation else { return }
                failure = error as? NativeFailure ?? NativeFailure(code: "INTERNAL", message: "Operation could not be completed.")
            }
        }
        self.task = task
        return task
    }
    func cancel() { task?.cancel() }
}

/// Thread-specific reaction and refresh paths, shared by the UI and behavioral tests.
@MainActor final class ContentThreadCommand: ContentCommand {
    @Published private(set) var reactionsBlocked = false
    private var reconciliationID = UUID()
    private struct UncertainReaction {
        let postID: Int64
        let commentID: Int64
        let page: Int64
        let opening: Bool
        let generation: Int
    }
    private var uncertain: UncertainReaction?

    @discardableResult
    func react(_ app: any ContentCommandContext, postID: Int64, commentID: Int64, action: String, page: Int64 = 1, opening: Bool = false) -> Task<Void, Never>? {
        guard !reactionsBlocked else { return nil }
        let generation = app.generation
        return run(app) {
            do {
                _ = try await app.request("thread.react", ["postId": .integer(postID), "commentId": .integer(commentID), "action": .string(action)])
                _ = try await app.request("thread.config", ["postId": .integer(postID)])
            } catch {
                // Cancellation can also mean the server accepted the spending mutation.
                if generation == app.generation {
                    self.reactionsBlocked = true
                    self.uncertain = UncertainReaction(postID: postID, commentID: commentID, page: opening ? 1 : page, opening: opening, generation: generation)
                    self.reconciliationID = UUID()
                }
                throw error
            }
        }
    }

    /// Only this dedicated repository operation guarantees a fresh network response.
    /// The receipt covers its raw page, never other floors retained by the Room window.
    func reconcileReactions(_ app: any ContentCommandContext, postID: Int64) async {
        guard let affected = uncertain, affected.postID == postID,
              affected.generation == app.generation else { return }
        let token = reconciliationID
        do {
            try Task.checkCancellation()
            let receipt = try await app.request("thread.reconcileReactions", ["postId": .integer(postID), "page": .integer(affected.page)])
            try Task.checkCancellation()
            guard affected.generation == app.generation, token == reconciliationID,
                  receipt["postId"]?.int == affected.postID,
                  receipt["page"]?.int == affected.page else { return }
            let covered = affected.opening
                ? receipt["openingCommentId"]?.int == affected.commentID
                : receipt["commentIds"]?.array?.contains(.integer(affected.commentID)) == true
            guard covered else { return }
            uncertain = nil
            reactionsBlocked = false
            failure = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, affected.generation == app.generation, token == reconciliationID else { return }
            failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
        }
    }

    func loadThread(_ app: any ContentCommandContext, postID: Int64, page: Int64, extend: Bool) async {
        let generation = app.generation
        do {
            _ = try await app.request("thread.load", ["postId": .integer(postID), "page": .integer(page), "extend": .bool(extend)])
            try Task.checkCancellation()
            guard generation == app.generation else { return }
            // This path supports offline fallback and partial-window merging. It is never
            // evidence that an uncertain reaction's affected floor was read from the server.
            failure = nil
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == app.generation else { return }
            failure = error as? NativeFailure ?? .init(code: "INTERNAL", message: "Operation could not be completed.")
        }
    }
}
