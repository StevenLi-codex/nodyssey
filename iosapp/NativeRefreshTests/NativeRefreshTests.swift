import Foundation

@main struct NativeRefreshTests {
    @MainActor static func main() async {
        var state = NativeRefreshState()
        precondition(!state.pull(progress: 0.4, dragging: true), "short pull must not give threshold feedback")
        precondition(state.pull(progress: 1, dragging: true), "crossing threshold must give feedback")
        precondition(!state.pull(progress: 1.3, dragging: true), "one feedback per drag")
        state.pull(progress: 0, dragging: false)
        precondition(state.phase == .idle, "short/nonrefreshing release must collapse")
        precondition(state.pull(progress: 1, dragging: true), "next drag rearms feedback")
        let token = UUID()
        precondition(state.begin(token))
        precondition(!state.begin(UUID()), "repeated pull may not replace active request")
        state.finish(UUID(), success: true)
        precondition(state.phase == .refreshing, "late wrong-token completion ignored")
        state.finish(token, success: false)
        precondition(state.phase == .idle, "failure cannot show check")
        print("PASS pull feedback, repeated admission, stale completion, failure")
        await concurrency()
    }

    @MainActor static func concurrency() async {
        let refresh = NativeRefreshCoordinator()
        let network = Gate()
        let observer = Gate()
        let settle = Gate()
        var requests = 0
        var completions = 0
        var phases: [NativeRefreshState.Phase] = []
        refresh.onChange = { phases.append($0.phase) }
        let first = Task { @MainActor in
            await refresh.refresh(completion: { completions += 1; await observer.wait(); return true }, settle: { await settle.wait() }) {
                requests += 1
                await network.wait()
            }
        }
        await network.entered()
        let repeatPull = Task { @MainActor in
            await refresh.refresh { requests += 100 }
        }
        await Task.yield()
        precondition(requests == 1 && refresh.state.phase == .refreshing, "repeated pull must share actual operation")
        network.release()
        await observer.entered()
        precondition(refresh.state.phase == .refreshing && completions == 1, "ack must not end spinner before observed completion")
        observer.release()
        await settle.entered()
        precondition(refresh.state.phase == .success, "successful unchanged response must show check")
        settle.release()
        await first.value; await repeatPull.value
        precondition(refresh.state.phase == .idle && requests == 1)

        let delayed = Gate()
        let cancelled = Task { @MainActor in
            await refresh.refresh { requests += 1; await delayed.wait() }
        }
        await delayed.entered()
        refresh.cancel(); refresh.appear()
        precondition(refresh.state.phase == .idle, "departure resets presentation immediately")
        let replacement = Task { @MainActor in await refresh.refresh { requests += 100 } }
        await Task.yield()
        precondition(requests == 2, "cancelled uncooperative work must drain before another request")
        delayed.release()
        await cancelled.value; await replacement.value
        precondition(refresh.state.phase == .idle && requests == 2, "late cancelled success cannot publish")
        phases.removeAll()
        await refresh.refresh(failure: { true }) { requests += 1 }
        precondition(!phases.contains(.success) && refresh.state.phase == .idle, "swallowed transport errors must never show check")
        phases.removeAll()
        await refresh.refresh(completion: { false }) {}
        precondition(!phases.contains(.success), "incomplete observation cannot show check")
        let alreadyCancelled = Task { @MainActor in
            await refresh.refresh { requests += 100 }
        }
        alreadyCancelled.cancel(); await alreadyCancelled.value
        precondition(requests == 3 && refresh.state.phase == .idle, "cancelled-before-start must not dispatch")
        print("PASS serial coalescing, actual observer await, unchanged success, departure, late completion, failure, incomplete observation, pre-start cancellation")

        let cancelledNetwork = Gate()
        let independentlyCancelled = Task { @MainActor in
            await refresh.refresh { await cancelledNetwork.wait() }
        }
        await cancelledNetwork.entered()
        independentlyCancelled.cancel()
        for _ in 0..<100 { await Task.yield() }
        precondition(refresh.state.phase == .idle, "task cancellation must remove spinner before an uncooperative transport drains")
        cancelledNetwork.release()
        await independentlyCancelled.value
        print("PASS cancellation immediately clears presentation while retaining serialization drain")

        let pendingCompletion = Gate()
        let awaitingObserver = Task { @MainActor in
            await refresh.refresh(completion: { await pendingCompletion.wait(); return true }) {}
        }
        await pendingCompletion.entered()
        phases.removeAll()
        refresh.cancel(); refresh.appear()
        precondition(refresh.state.phase == .idle, "departure during observer completion clears presentation")
        var replacementDispatched = false
        let competing = Task { @MainActor in
            await refresh.refresh { replacementDispatched = true }
        }
        await Task.yield()
        precondition(!replacementDispatched, "observer completion is part of the serialized operation")
        pendingCompletion.release()
        await awaitingObserver.value; await competing.value
        precondition(!replacementDispatched && !phases.contains(.success), "old observer success cannot appear in a replacement owner")
        await refresh.refresh { replacementDispatched = true }
        precondition(replacementDispatched && refresh.state.phase == .idle, "a drained cancellation must not permanently block future refresh")
        print("PASS observer-wait cancellation fences late success and permits refresh after drain")
    }
}

@MainActor private final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func wait() async {
        didEnter = true
        enteredWaiter?.resume(); enteredWaiter = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func entered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
