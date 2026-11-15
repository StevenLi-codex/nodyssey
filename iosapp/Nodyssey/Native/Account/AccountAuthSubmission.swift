import Foundation
import Combine
import NodysseyNativeCore

/// Memory-only native form owner. The app remains the sole session authority.
/// Kept separate from the view so suspended request/teardown ordering is testable.
@MainActor final class AccountAuthSubmission: ObservableObject {
    @Published var form = AccountAuthState()
    @Published var failure: NativeFailure?
    @Published private(set) var resetSignal = 0
    private var task: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var hasNativeAttempt = false
    private var presentation: UUID?

    func submit(app: NativeAppModel, onSigned: @escaping @MainActor () -> Void) {
        let challenge = form.challenge
        let args: [String: JSONValue] = challenge.map { ["challengeId": .string($0), "code": .string(form.code)] }
            ?? ["account": .string(form.account), "password": .string(form.password), "verificationToken": .string(form.token)]
        guard let ticket = form.begin() else { return }
        // Register synchronously, before the request Task can dispatch a mutation.
        guard let lease = presentation ?? app.beginAuthenticationPresentation() else {
            form.failed(ticket)
            return
        }
        presentation = lease
        hasNativeAttempt = true
        failure = nil
        let previousCleanup = cleanup
        task = Task {
            await previousCleanup?.value
            guard !Task.isCancelled, form.accepts(ticket) else { return }
            do {
                let result = try await app.request(challenge == nil ? "session.signIn" : "session.verifyTwoFactor", args)
                guard !Task.isCancelled, form.accepts(ticket) else { return }
                switch result.nativeString("status") {
                case "SIGNED":
                    hasNativeAttempt = false
                    app.endAuthenticationPresentation(presentation)
                    presentation = nil
                    form.cancel()
                    onSigned()
                case "TWO_FACTOR_REQUIRED":
                    guard let handle = result.nativeString("challengeId"), form.acceptChallenge(handle, ticket: ticket) else {
                        form.failed(ticket); failure = NativeFailure(code: "INVALID_DATA", message: ""); return
                    }
                default:
                    form.failed(ticket); resetSignal += 1
                    failure = NativeFailure(code: "REFUSED", message: "")
                }
            } catch {
                guard !Task.isCancelled, form.accepts(ticket) else { return }
                if (error as? NativeFailure)?.code == "SIGN_IN_SUPERSEDED" { form.cancel() }
                else { form.failed(ticket) }
                resetSignal += 1
                failure = NativeFailure(code: (error as? NativeFailure)?.code ?? "INTERNAL", message: "")
            }
        }
    }

    /// Cleanup outlives disappearance. Retry/browser handoff waits for the old
    /// cancellation AND request drain; an old cancel cannot supersede a new login.
    @discardableResult func cancel(app: NativeAppModel) -> Task<Void, Never>? {
        task?.cancel()
        let previousTask = task
        task = nil
        form.cancel(); failure = nil; resetSignal += 1
        let lease = presentation
        presentation = nil
        guard hasNativeAttempt else {
            app.endAuthenticationPresentation(lease)
            return cleanup
        }
        hasNativeAttempt = false
        let previousCleanup = cleanup
        let work = Task {
            await previousCleanup?.value
            do { _ = try await app.request("session.cancelSignIn") } catch { /* Cleanup never publishes success. */ }
            await previousTask?.value
            app.endAuthenticationPresentation(lease)
        }
        cleanup = work
        return work
    }
}
