import Foundation
import Testing
import NodysseyNativeCore
@testable import AccountBehavior

@Test @MainActor func keywordRecoveryPreservesNewerInputWithoutAnotherWrite() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    var writes = 0
    var reads = 0
    var published: JSONValue = .null
    draft.perform(write, action: action, request: { operation, arguments in
        if operation == "keywords.add" {
            writes += 1
            #expect(arguments["text"] == .string("A"))
            throw NativeFailure(code: "NETWORK", message: "")
        }
        reads += 1
        return .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { published = $0 })
    await eventually { action.state.phase == .uncertain }
    draft.text = "B"
    action.refreshOnly()
    await eventually { action.state.phase == .reconciled }
    #expect(draft.text == "B")
    #expect(published == .array([.string("A")]))
    #expect(writes == 1 && reads == 1)
    action.cancel()
}

@Test @MainActor func acknowledgedKeywordSuccessClearsOnlyUnchangedCapturedInput() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    draft.perform(write, action: action, request: { operation, _ in
        #expect(operation == "keywords.add" || operation == "keywords.get")
        return operation == "keywords.add" ? .object([:]) : .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { _ in })
    await eventually { action.state.phase == .verified }
    #expect(draft.text.isEmpty)
    action.cancel()
}

@Test @MainActor func keywordRecoveryKeepsAAfterEditBThenA() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    var writes = 0
    draft.perform(write, action: action, request: { operation, _ in
        if operation == "keywords.add" { writes += 1; throw NativeFailure(code: "NETWORK", message: "") }
        return .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { _ in })
    await eventually { action.state.phase == .uncertain }
    draft.text = "B"
    draft.text = "A"
    action.refreshOnly()
    await eventually { action.state.phase == .reconciled }
    #expect(draft.text == "A")
    #expect(writes == 1)
    action.cancel()
}

@Test @MainActor func keywordRecoveryKeepsInputWhenRegexKindChanges() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    draft.perform(write, action: action, request: { operation, _ in
        if operation == "keywords.add" { throw NativeFailure(code: "NETWORK", message: "") }
        return .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { _ in })
    await eventually { action.state.phase == .uncertain }
    draft.regex = true
    action.refreshOnly()
    await eventually { action.state.phase == .reconciled }
    #expect(draft.text == "A")
    action.cancel()
}

@Test(arguments: [false, true]) @MainActor func cancelledOrSupersededKeywordRecoveryCannotPublishOrClearDraft(cancel: Bool) async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    var generation = 1
    var release: CheckedContinuation<JSONValue, Never>?
    draft.text = "A"
    let write = draft.add()
    var published = 0
    draft.perform(write, action: action, request: { operation, _ in
        if operation == "keywords.add" { throw NativeFailure(code: "NETWORK", message: "") }
        return await withCheckedContinuation { release = $0 }
    }, currentGeneration: { generation }, publish: { _ in published += 1 })
    await eventually { action.state.phase == .uncertain }
    action.refreshOnly()
    await eventually { release != nil }
    if cancel { action.cancel() } else { generation = 2 }
    release?.resume(returning: .array([.string("A")]))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(published == 0)
    #expect(draft.text == "A")
    #expect(action.state.phase != .reconciled)
    action.cancel()
}

@Test(arguments: ["edit", "reenter", "kind", "kindRoundTrip", "beforeConfirm"])
@MainActor func acknowledgedKeywordWritePreservesRevisedDraft(change: String) async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    var release: CheckedContinuation<JSONValue, Never>?
    if change == "beforeConfirm" { draft.text = "B" }
    draft.perform(write, action: action, request: { operation, arguments in
        if operation == "keywords.add" {
            #expect(arguments["text"] == .string("A"))
            return await withCheckedContinuation { release = $0 }
        }
        return .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { _ in })
    await eventually { release != nil }
    switch change {
    case "edit": draft.text = "B"
    case "reenter": draft.text = "B"; draft.text = "A"
    case "kind": draft.regex = true
    case "kindRoundTrip": draft.regex = true; draft.regex = false
    default: break
    }
    let expected = draft.text
    release?.resume(returning: .object([:]))
    await eventually { action.state.phase == .verified }
    #expect(draft.text == expected)
    action.cancel()
}

@Test @MainActor func removingKeywordCannotClearUnsubmittedInput() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "B"
    let write = AccountPendingWrite("keywords.remove", ["kind": .string("BLOCK"), "text": .string("A")])
    draft.perform(write, action: action, request: { operation, _ in
        operation == "keywords.remove" ? .object([:]) : .array([])
    }, currentGeneration: { 1 }, publish: { _ in })
    await eventually { action.state.phase == .verified }
    #expect(draft.text == "B")
    action.cancel()
}

@Test(arguments: [false, true]) @MainActor func lateKeywordAcknowledgementCannotClearAfterCancellationOrSessionChange(cancel: Bool) async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    var generation = 1
    var release: CheckedContinuation<JSONValue, Never>?
    var operations: [String] = []
    draft.text = "A"
    draft.perform(draft.add(), action: action, request: { operation, _ in
        operations.append(operation)
        return await withCheckedContinuation { release = $0 }
    }, currentGeneration: { generation }, publish: { _ in Issue.record("Stale write must not read back") })
    await eventually { release != nil }
    if cancel { action.cancel() } else { generation = 2 }
    release?.resume(returning: .object([:]))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(draft.text == "A")
    #expect(operations == ["keywords.add"])
    #expect(action.state.phase != .verified)
    action.cancel()
}

@Test @MainActor func acknowledgedReadbackFailureRecoveryDoesNotConsumeNextDraft() async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    var operations: [String] = []
    var reads = 0
    var published: JSONValue = .null
    draft.text = "A"
    draft.perform(draft.add(), action: action, request: { operation, _ in
        operations.append(operation)
        if operation == "keywords.add" { return .object([:]) }
        reads += 1
        if reads == 1 { throw NativeFailure(code: "NETWORK", message: "") }
        return .array([.string("A")])
    }, currentGeneration: { 1 }, publish: { published = $0 })
    await eventually { action.state.phase == .savedNeedsRefresh }
    #expect(draft.text.isEmpty)
    draft.text = "B"
    action.refreshOnly()
    await eventually { action.state.phase == .verified }
    #expect(draft.text == "B")
    #expect(operations == ["keywords.add", "keywords.get", "keywords.get"])
    #expect(published == .array([.string("A")]))
    action.cancel()
}

@Test(arguments: [false, true]) @MainActor func editingDuringKeywordRecoveryKeepsLatestInput(switchKind: Bool) async {
    let draft = AccountKeywordDraft()
    let action = AccountAction()
    draft.text = "A"
    let write = draft.add()
    var release: CheckedContinuation<JSONValue, Never>?
    var operations: [String] = []
    var published: JSONValue = .null
    draft.perform(write, action: action, request: { operation, arguments in
        operations.append(operation)
        #expect(arguments["kind"] == .string("BLOCK"))
        if operation == "keywords.add" { throw NativeFailure(code: "NETWORK", message: "") }
        return await withCheckedContinuation { release = $0 }
    }, currentGeneration: { 1 }, publish: { published = $0 })
    await eventually { action.state.phase == .uncertain }
    action.refreshOnly(); action.refreshOnly()
    await eventually { release != nil }
    draft.text = "B"
    if switchKind { draft.regex = true }
    draft.perform(draft.add(), action: action, request: { operation, _ in
        operations.append(operation); return .null
    }, currentGeneration: { 1 }, publish: { _ in })
    release?.resume(returning: .array([.string("A")]))
    await eventually { action.state.phase == .reconciled }
    #expect(draft.text == "B")
    #expect(operations == ["keywords.add", "keywords.get"])
    #expect(published == (switchKind ? .null : .array([.string("A")])))
    action.cancel()
}
