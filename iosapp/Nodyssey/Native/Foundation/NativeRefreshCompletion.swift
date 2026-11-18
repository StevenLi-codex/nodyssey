import Foundation
import NodysseyNativeCore

/// Command receipts do not establish completion of a retained list observation.
enum NativeRefreshCompletionMode: Equatable {
    case paging
    case revision
}

@MainActor final class NativeRefreshCompletion {
    let id = UUID()
    let operation: String
    let arguments: [String: JSONValue]
    let mode: NativeRefreshCompletionMode
    let revision: UInt64
    let pager: String?
    var sawLoading = false
    var acceptedTerminal = false
    var acknowledged = false
    var result: Bool?
    var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(operation: String, arguments: [String: JSONValue], mode: NativeRefreshCompletionMode,
         revision: UInt64, pager: String?) {
        self.operation = operation
        self.arguments = arguments
        self.mode = mode
        self.revision = revision
        self.pager = pager
    }

    func resolve(_ success: Bool) {
        guard result == nil else { return }
        result = success
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: success) }
    }

    deinit {
        for continuation in waiters.values { continuation.resume(returning: false) }
    }
}
