import Foundation
import Testing
@testable import AccountBehavior

@Test @MainActor func pageRefreshJoinsRealWorkAndRejectsReplacedKey() async {
    let work = AccountReadFlightState()
    var releases: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    var accepted: [String] = []
    let first = Task { await work.run(key: "page1", current: { true }) { isCurrent in
        calls += 1
        await withCheckedContinuation { releases.append($0) }
        guard isCurrent() else { return false }
        accepted.append("old"); return true
    } }
    while releases.isEmpty { await Task.yield() }
    var joinedDone = false
    let joined = Task { let result = await work.run(key: "page1", current: { true }) { _ in calls += 1; return true }; joinedDone = true; return result }
    for _ in 0..<20 { await Task.yield() }
    #expect(calls == 1 && !joinedDone)
    let replacement = Task { await work.run(key: "page2", current: { true }) { isCurrent in
        guard isCurrent() else { return false }; accepted.append("new"); return true
    } }
    #expect(await replacement.value)
    releases[0].resume()
    #expect(await first.value == false)
    #expect(await joined.value == false)
    #expect(accepted == ["new"])
    #expect(!work.isLoading)
}
