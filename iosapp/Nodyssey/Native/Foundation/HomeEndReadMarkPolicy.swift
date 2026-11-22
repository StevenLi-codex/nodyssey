import Foundation
import NodysseyNativeCore

/// Which operations can rewrite the read-mark projection the Home feed renders.
/// Kept free of UIKit so the fence itself is testable off-device.
enum HomeEndReadMarkPolicy {
    nonisolated static func conflicts(_ operation: String) -> Bool {
        switch operation {
        case "thread.markRead", "thread.load", "thread.react", "thread.collect", "thread.reconcileReactions",
             "editor.post.publish", "editor.edit.save",
             // The accepted-reply hook advances the same read-mark table this paint
             // correlates with, so it is a conflict even though it is not a mark.
             "editor.comment.publish",
             // History undo/removal rewrite the same rows; never treat them as paint.
             "history.restore", "history.remove", "history.clear",
             "paging.refresh", "paging.retry", "app.foreground", "settings.set", "settings.homeBoards": return true
        default: return false
        }
    }
}

/// Pass-through for editors that publish through their own transport. Only the
/// conflict fence is added: operation, payload, cancellation, drain and delivery
/// stay the base transport's.
struct PaintObservedTransport: NativeTransport {
    let base: any NativeTransport
    weak var app: NativeAppModel?

    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let counted = await app?.beginPaintObserved(operation) ?? false
        do {
            let value = try await base.request(operation, arguments)
            if counted { await app?.endPaintObserved(operation) }
            return value
        } catch {
            if counted { await app?.endPaintObserved(operation) }
            throw error
        }
    }

    func request(_ operation: String, _ arguments: [String: JSONValue],
                 onTermination: @escaping @Sendable () -> Void) async throws -> JSONValue {
        let counted = await app?.beginPaintObserved(operation) ?? false
        do {
            let value = try await base.request(operation, arguments, onTermination: onTermination)
            if counted { await app?.endPaintObserved(operation) }
            return value
        } catch {
            if counted { await app?.endPaintObserved(operation) }
            throw error
        }
    }

    func observe(_ operation: String, _ arguments: [String: JSONValue]) -> AsyncThrowingStream<JSONValue, Error> {
        base.observe(operation, arguments)
    }
}

