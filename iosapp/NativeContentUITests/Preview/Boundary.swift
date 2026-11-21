// Executable app/transport boundary for preview tests. The loader, NativeStore,
// NativeRequestState and JSON DTO implementation are the real production files.
import Foundation
import Combine
import NodysseyNativeCore

@MainActor final class NativeAppModel: ObservableObject {
    let transport: any NativeTransport
    @Published var generation = 4
    @Published var session: JSONValue = .object(["identityEpoch": .string("epoch-a")])
    @Published var site: JSONValue = .object(["current": .string("NODESEEK")])
    init(transport: any NativeTransport) { self.transport = transport }
    func register(_ store: NativeStore) {} // App's weak invalidation registry is out of scope.
}
