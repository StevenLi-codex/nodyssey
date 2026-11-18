import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test @MainActor func simultaneousThreadRefreshAndToolbarJoinOneRealRequest() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: [CheckedContinuation<JSONValue, Never>] = []
    app.respond = { _, _ in await withCheckedContinuation { pending.append($0) } }
    let toolbar = Task { await command.loadThread(app, postID: 42, page: 2, extend: true) }
    while pending.isEmpty { await Task.yield() }
    let pull = Task { await command.loadThread(app, postID: 42, page: 2, extend: true) }
    for _ in 0..<50 { await Task.yield() }
    #expect(app.calls.count == 1, "Pull must join the toolbar's held network/cache operation")
    for continuation in pending { continuation.resume(returning: .object(["postId": .integer(42)])) }
    await toolbar.value
    await pull.value
}

@Test(arguments: ["failure", "cancellation", "generation", "null", "wrongPost"])
@MainActor func threadRefreshRejectsIncompleteOrObsoleteCompletion(_ outcome: String) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in
        switch outcome {
        case "failure": throw NativeFailure(code: "NETWORK", message: "Load failed")
        case "cancellation": throw CancellationError()
        case "generation": app.generation += 1
        case "null": return .null
        case "wrongPost": return .object(["postId": .integer(99)])
        default: break
        }
        return .object(["postId": .integer(42)])
    }
    let success = await command.loadThread(app, postID: 42, page: 1, extend: true)
    #expect(!success)
    #expect(command.failure?.code == (outcome == "failure" ? "NETWORK" : nil))
}

@Test @MainActor func oldPageFailureCannotOverwriteNewPageSuccess() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var old: CheckedContinuation<JSONValue, any Error>?
    app.respond = { _, args in
        if args["page"]?.int == 1 { return try await withCheckedThrowingContinuation { old = $0 } }
        return .object(["postId": .integer(42)])
    }
    let first = Task { await command.loadThread(app, postID: 42, page: 1, extend: true) }
    while old == nil { await Task.yield() }
    let second = await command.loadThread(app, postID: 42, page: 2, extend: true)
    #expect(second)
    old?.resume(throwing: NativeFailure(code: "OLD", message: "Old page failed"))
    let oldSuccess = await first.value
    #expect(!oldSuccess)
    #expect(command.failure == nil)
    #expect(app.calls.count == 2)
}

@Test @MainActor func cancellingOneThreadWaiterDoesNotCancelJoinedRequest() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: CheckedContinuation<JSONValue, Never>?
    var cancelledWaiterReturned = false
    app.respond = { _, _ in await withCheckedContinuation { pending = $0 } }
    let first = Task {
        let result = await command.loadThread(app, postID: 42, page: 2, extend: true)
        cancelledWaiterReturned = true
        return result
    }
    while pending == nil { await Task.yield() }
    first.cancel()
    for _ in 0..<50 { await Task.yield() }
    #expect(cancelledWaiterReturned, "Cancellation must release the visual waiter before transport drain")
    let second = Task { await command.loadThread(app, postID: 42, page: 2, extend: true) }
    for _ in 0..<50 { await Task.yield() }
    #expect(app.calls.count == 1)
    pending?.resume(returning: .object(["postId": .integer(42)]))
    let cancelled = await first.value
    let joined = await second.value
    #expect(!cancelled)
    #expect(joined)
}

@Test @MainActor func threadOwnerCancellationRejectsLateUncooperativeSuccess() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: CheckedContinuation<JSONValue, Never>?
    app.respond = { _, _ in await withCheckedContinuation { pending = $0 } }
    let first = Task { await command.loadThread(app, postID: 42, page: 2, extend: true) }
    while pending == nil { await Task.yield() }
    command.cancel()
    var rejectedJoinReturned = false
    let rejectedJoin = Task {
        let result = await command.loadThread(app, postID: 42, page: 2, extend: true)
        rejectedJoinReturned = true
        return result
    }
    for _ in 0..<50 { await Task.yield() }
    #expect(rejectedJoinReturned, "A cancelled draining flight must refuse promptly, not register a stranded waiter")
    #expect(app.calls.count == 1)
    pending?.resume(returning: .object(["postId": .integer(42)]))
    let success = await first.value
    let rejectedSuccess = await rejectedJoin.value
    #expect(!rejectedSuccess)
    #expect(!success)
    #expect(command.failure == nil)
}

@Test @MainActor func threadLoadOnlyClearsItsOwnFailureAndPreservesBusinessError() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Load failed") }
    #expect(await command.loadThread(app, postID: 42, page: 1, extend: true) == false)
    app.respond = { _, _ in .object(["postId": .integer(42)]) }
    #expect(await command.loadThread(app, postID: 42, page: 1, extend: true))
    #expect(command.failure == nil)
    let business = NativeFailure(code: "SPENDING", message: "Indeterminate reaction")
    command.failure = business
    #expect(await command.loadThread(app, postID: 42, page: 1, extend: true))
    #expect(command.failure == business)
}

@Test @MainActor func replacementAndExtensionLoadsNeverShareARequest() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: [CheckedContinuation<JSONValue, Never>] = []
    app.respond = { _, _ in await withCheckedContinuation { pending.append($0) } }
    let first = Task { await command.loadThread(app, postID: 42, page: 1, extend: true) }
    while pending.count < 1 { await Task.yield() }
    let second = Task { await command.loadThread(app, postID: 42, page: 1, extend: false) }
    while pending.count < 2 { await Task.yield() }
    #expect(app.calls.map { $0.1["extend"] } == [.bool(true), .bool(false)])
    pending.forEach { $0.resume(returning: .object(["postId": .integer(42)])) }
    _ = await first.value
    _ = await second.value
}

@Test(arguments: ["group", "generation", "cancel", "failure"])
@MainActor func notificationRefreshCannotPublishAStaleOrFailedCompletion(_ outcome: String) async {
    let app = ScriptedContentContext()
    let refresh = ContentNotificationRefresh()
    var pending: CheckedContinuation<Bool, Never>?
    let task = Task {
        await refresh.perform(app, group: "INTERACTIONS") {
            await withCheckedContinuation { pending = $0 }
        }
    }
    while pending == nil { await Task.yield() }
    #expect(!refresh.succeeded)
    #expect(refresh.group == "INTERACTIONS")
    switch outcome {
    case "group": refresh.invalidate() // Includes switching away and back before completion.
    case "generation": app.generation += 1
    case "cancel": task.cancel()
    default: break
    }
    pending?.resume(returning: outcome != "failure")
    await task.value
    #expect(!refresh.succeeded)
}

@Test @MainActor func notificationAcceptedCompletionCanRecoverAfterFailure() async {
    let app = ScriptedContentContext()
    let refresh = ContentNotificationRefresh()
    await refresh.perform(app, group: "MESSAGES") { false }
    #expect(!refresh.succeeded)
    await refresh.perform(app, group: "MESSAGES") { true }
    #expect(refresh.succeeded)
}

@Test @MainActor func cancelledBeforeThreadAdmissionDoesNotDispatchOrReportSuccess() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    let load = Task { await command.loadThread(app, postID: 42, page: 1, extend: true) }
    load.cancel()
    let success = await load.value
    #expect(!success)
    #expect(app.calls.isEmpty)
}

@Test @MainActor func lateOldIdentityErrorCannotReplaceCurrentThreadFailure() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pending: CheckedContinuation<JSONValue, any Error>?
    app.respond = { _, _ in try await withCheckedThrowingContinuation { pending = $0 } }
    let load = Task { await command.loadThread(app, postID: 42, page: 1, extend: true) }
    while pending == nil { await Task.yield() }
    app.generation += 1
    let current = NativeFailure(code: "CURRENT", message: "Current identity failure")
    command.failure = current
    pending?.resume(throwing: NativeFailure(code: "OLD", message: "Old identity failure"))
    let success = await load.value
    #expect(!success)
    #expect(command.failure == current)
}

/// No network or live spending: only the bridge boundary is scripted.
@MainActor final class ScriptedContentContext: ContentCommandContext {
    var generation = 0
    var calls: [(String, [String: JSONValue])] = []
    var respond: @MainActor (String, [String: JSONValue]) async throws -> JSONValue = { _, _ in .null }
    func request(_ operation: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        calls.append((operation, arguments))
        return try await respond(operation, arguments)
    }
}

@Test @MainActor func failedReactionStaysBlockedAfterTrackBookmarkAndLocalConfigUntilRealReload() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { operation, _ in
        if operation == "thread.react" { throw NativeFailure(code: "NETWORK", message: "Indeterminate") }
        return .object(["postId": .integer(42)])
    }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    #expect(command.reactionsBlocked)
    for operation in ["tracked.add", "thread.collect", "thread.config"] {
        await command.run(app) { _ = try await app.request(operation, ["postId": .integer(42)]) }?.value
        #expect(command.failure == nil)
        #expect(command.reactionsBlocked, "Unrelated \(operation) must not reconcile an uncertain reaction")
    }
    await command.loadThread(app, postID: 42, page: 1, extend: false)
    #expect(command.reactionsBlocked)
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 1)
    #expect(app.calls.last?.0 == "thread.load")
}

@Test @MainActor func reloadStartedBeforeReactionCannotReconcileItsLaterFailure() async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    var pendingLoad: CheckedContinuation<JSONValue, Never>?
    app.respond = { operation, _ in
        if operation == "thread.load" { return await withCheckedContinuation { pendingLoad = $0 } }
        throw NativeFailure(code: "NETWORK", message: "Indeterminate")
    }
    let load = Task { await command.loadThread(app, postID: 42, page: 1, extend: false) }
    while pendingLoad == nil { await Task.yield() }
    await command.react(app, postID: 42, commentID: 7, action: "ChickenLeg")?.value
    #expect(command.reactionsBlocked)
    pendingLoad?.resume(returning: .object(["postId": .integer(42)]))
    await load.value
    #expect(command.reactionsBlocked, "An older refresh cannot reconcile a later indeterminate mutation")
}

@Test(arguments: ["failure", "null", "wrongThread", "session", "cancelled"])
@MainActor func incompleteReloadCannotUnlockReaction(_ outcome: String) async {
    let app = ScriptedContentContext()
    let command = ContentThreadCommand()
    app.respond = { _, _ in throw NativeFailure(code: "NETWORK", message: "Indeterminate") }
    await command.react(app, postID: 42, commentID: 7, action: "Dislike")?.value
    app.respond = { _, _ in
        switch outcome {
        case "failure": throw NativeFailure(code: "NETWORK", message: "Load failed")
        case "null": return .null
        case "wrongThread": return .object(["postId": .integer(99)])
        case "session": app.generation += 1
        case "cancelled": throw CancellationError()
        default: break
        }
        return .object(["postId": .integer(42)])
    }
    await command.loadThread(app, postID: 42, page: 1, extend: false)
    #expect(command.reactionsBlocked)
    #expect(command.react(app, postID: 42, commentID: 7, action: "Dislike") == nil)
    #expect(app.calls.filter { $0.0 == "thread.react" }.count == 1)
}
