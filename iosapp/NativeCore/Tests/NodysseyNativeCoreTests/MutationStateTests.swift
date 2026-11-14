import Foundation
import Testing
@testable import NodysseyNativeCore

struct MutationStateTests {
    @Test @MainActor func editingThenRestoringTextDoesNotEraseNewDraftOnCompletion() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeMutationState(draft: "same text")
        let task = Task { try await state.submit(using: transport, operation: "send", draftKey: "content") }
        try await transport.waitForCalls(1)
        state.draft = "edited"
        state.draft = "same text"
        await transport.complete(0, .success(.null))
        _ = try await task.value
        #expect(state.draft == "same text")
    }

    @Test @MainActor func overlappingSendIsRejectedAndFailedDraftSurvives() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeMutationState(draft: "unsent text")
        let first = Task { try await state.submit(using: transport, operation: "send", draftKey: "content") }
        try await transport.waitForCalls(1)
        #expect(state.isSubmitting)
        await #expect(throws: NativeFailure(code: "IN_FLIGHT", message: "A submission is already in progress")) {
            try await state.submit(using: transport, operation: "publish", draftKey: "content")
        }
        #expect(await transport.arguments == [["content": .string("unsent text")]])
        let error = NativeFailure(code: "REJECTED", message: "Not sent")
        await transport.complete(0, .failure(error))
        await #expect(throws: error) { try await first.value }
        #expect(state.draft == "unsent text")
        #expect(state.failure == error)
        #expect(!state.isSubmitting)
    }

    @Test @MainActor func successfulSubmitClearsOnlyTheSubmittedDraft() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeMutationState(draft: "old text")
        let first = Task { try await state.submit(using: transport, operation: "publish", draftKey: "body") }
        try await transport.waitForCalls(1)
        state.draft = "new text typed during upload"
        await transport.complete(0, .success(.integer(9007199254740993)))
        #expect(try await first.value == .integer(9007199254740993))
        #expect(state.draft == "new text typed during upload")
        let second = Task { try await state.submit(using: transport, operation: "publish", draftKey: "body") }
        try await transport.waitForCalls(2)
        await transport.complete(1, .success(.null))
        _ = try await second.value
        #expect(state.draft.isEmpty)
        #expect(state.failure == nil)
    }

    @Test @MainActor func accountSwitchFencesOldMutationAndDoesNotClearNewDraft() async throws {
        let transport = SyntheticSuspendedTransport()
        let state = NativeMutationState(draft: "account-A secret")
        let first = Task { try await state.submit(using: transport, operation: "send", draftKey: "content") }
        try await transport.waitForCalls(1)
        state.invalidate()
        #expect(state.draft.isEmpty)
        state.draft = "account-B text"
        let second = Task { try await state.submit(using: transport, operation: "send", draftKey: "content") }
        try await transport.waitForCalls(2)
        await transport.complete(0, .success(.null))
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(state.isSubmitting)
        #expect(state.draft == "account-B text")
        await transport.complete(1, .failure(NativeFailure(code: "OFFLINE", message: "Offline")))
        _ = await second.result
        #expect(state.draft == "account-B text")
        #expect(!state.isSubmitting)
    }
}
