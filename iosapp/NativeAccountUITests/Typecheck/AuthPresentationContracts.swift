// Signature-only declarations for the public lease used by the native form.
// Kept separate from the concurrently owned profile contract.
import Foundation
extension NativeAppModel {
    func beginAuthenticationPresentation() -> UUID? { fatalError() }
    func endAuthenticationPresentation(_ token: UUID?) { fatalError() }
}
