import Foundation
#if canImport(Combine)
import Combine
#endif

/// Complete owner/content boundary, shared by the UI and executable cache tests.
struct NativeRenderingInput<Content: Equatable>: Equatable {
    let app: ObjectIdentifier
    let generation: Int
    let identityEpoch: String?
    let content: Content
}

/// One transient projection per retained view owner. The complete input is compared,
/// not a lossy hash/revision. Replacing it releases the previous input and output.
/// No published state: a synchronous read never schedules a SwiftUI body update.
@MainActor
final class NativeRenderingMemo<Key: Equatable, Value> {
    private var entry: (key: Key, value: Value)?

    func value(for key: Key, make: () -> Value) -> Value {
        if let entry, entry.key == key { return entry.value }
        let value = make()
        entry = (key, value)
        return value
    }
}

#if canImport(Combine)
extension NativeRenderingMemo: ObservableObject {}
#endif
