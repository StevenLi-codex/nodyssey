import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

private func topSnapshot(page: Int64, rows: [Int64], firstPage: Int64 = 1, status: String = "NotLoading", pager: String = "pager") -> JSONValue {
    .object(["pagerId": .string(pager), "page": .integer(page), "placeholdersBefore": .integer(0),
             "placeholdersAfter": .integer(0), "itemCount": .integer(Int64(rows.count)),
             "remoteRefreshComplete": .bool(true),
             "refresh": .object(["status": .string(status)]),
             "items": .array(rows.enumerated().map { index, id in
                 .object(["summary": .object(["postId": .integer(id)]), "page": .integer(firstPage + Int64(index))])
             })])
}

@Test func topRefreshMustDistinguishPagerStartFromLoadedWindowTop() throws {
    // Page one present in a jumped pager is still not proof that refresh fetches page one.
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 8, rows: [41], firstPage: 1), atTop: false) == .replace)
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 1, rows: [41], firstPage: 1), atTop: false) == .refresh(scroll: 41))
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 1, rows: [41], firstPage: 1), atTop: true) == .refresh(scroll: nil))
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 1, rows: []), atTop: true) == .refresh(scroll: nil))
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 1, rows: [41], firstPage: 4), atTop: false) == .refresh(scroll: nil))
}

@Test @MainActor func replacementWaitRequiresItsActualPageOneTerminalAndRejectsLateOwner() async {
    let ticket = ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    let flight = ContentFeedTopRefreshFlight()
    let wait = Task { await flight.wait(owner: ticket, pager: "new", start: {}) }
    await Task.yield()
    flight.update(topSnapshot(page: 1, rows: [1], status: "NotLoading", pager: "old"), current: ticket)
    #expect(flight.pending)
    flight.update(topSnapshot(page: 1, rows: [1], status: "Loading", pager: "new"), current: ticket)
    #expect(flight.pending)
    flight.update(topSnapshot(page: 1, rows: [], pager: "new"), current: ticket)
    #expect(await wait.value)
    #expect(!flight.pending)

    let cancelled = Task { await flight.wait(owner: ticket, pager: "later", start: {}) }
    await Task.yield()
    let other = ContentFeedTicket(generation: 7, board: "life", sort: "LAST_REPLY", observation: UUID())
    flight.update(topSnapshot(page: 1, rows: [2], pager: "later"), current: other)
    #expect(!(await cancelled.value))
}

@Test @MainActor func replacementWaitJoinsWithoutStartingTwiceAndCancellationReleasesOnlyOneWaiter() async {
    let ticket = ContentFeedTicket(generation: 3, board: "life", sort: "POST_TIME", observation: UUID())
    let flight = ContentFeedTopRefreshFlight()
    var starts = 0
    let first = Task { await flight.wait(owner: ticket, pager: "one", start: { starts += 1 }) }
    while !flight.pending { await Task.yield() }
    let joined = Task { await flight.wait(owner: ticket, pager: "one", start: { starts += 1 }) }
    await Task.yield()
    first.cancel()
    #expect(!(await first.value))
    #expect(starts == 1)
    #expect(flight.pending)
    flight.update(topSnapshot(page: 1, rows: [99], pager: "one"), current: ticket)
    #expect(await joined.value)
    #expect(starts == 1)
}

@Test @MainActor func replacementErrorsAndWatchdogNeverReportSuccess() async {
    let ticket = ContentFeedTicket(generation: 3, board: "life", sort: "POST_TIME", observation: UUID())
    let flight = ContentFeedTopRefreshFlight()
    let error = Task { await flight.wait(owner: ticket, pager: "one", start: {}) }
    while !flight.pending { await Task.yield() }
    flight.update(topSnapshot(page: 1, rows: [], status: "Error", pager: "one"), current: ticket)
    #expect(!(await error.value))
    #expect(!(await flight.wait(owner: ticket, pager: "two", timeout: 0.001, start: {})))
    #expect(!flight.pending)
}

@Test func failedPageOneShellRequestsReplacementAgain() throws {
    #expect(try ContentFeedTopRefresh.plan(topSnapshot(page: 1, rows: [81], firstPage: 8, status: "Error"), atTop: true) == .replace)
}

@Test @MainActor func cachedTerminalMustHaveCurrentRemotePresentationReceipt() async {
    let owner = ContentFeedTicket(generation: 1, board: "tech", sort: "LAST_REPLY", observation: UUID())
    let flight = ContentFeedTopRefreshFlight()
    let waiter = Task { await flight.wait(owner: owner, pager: "new", start: {}) }
    while !flight.pending { await Task.yield() }
    var snapshot = topSnapshot(page: 1, rows: [1], pager: "new").object!
    snapshot.removeValue(forKey: "remoteRefreshComplete")
    flight.update(.object(snapshot), current: owner)
    #expect(flight.pending, "missing provenance fails closed")
    snapshot["remoteRefreshComplete"] = .bool(false)
    flight.update(.object(snapshot), current: owner)
    #expect(flight.pending, "cached terminal cannot complete the remote read")
    snapshot["remoteRefreshComplete"] = .bool(true)
    flight.update(.object(snapshot), current: owner)
    #expect(await waiter.value)
}
