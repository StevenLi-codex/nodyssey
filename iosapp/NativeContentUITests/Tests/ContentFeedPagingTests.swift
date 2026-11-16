import Foundation
import Testing
@testable import NativeContentState
import NodysseyNativeCore

@Test func feedViewportUsesIntersectingTopRowNotPrefetchOrderAndRejectsOldOwners() {
    let ticket = ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    let stale = ContentFeedTicket(generation: 6, board: "tech", sort: "LAST_REPLY", observation: UUID())
    let viewport = CGRect(x: 0, y: 0, width: 320, height: 500)
    let samples = [
        ContentFeedVisibleRow(ticket: ticket, id: 99, page: 12, frame: CGRect(x: 0, y: 510, width: 320, height: 80)),
        ContentFeedVisibleRow(ticket: ticket, id: 9007199254740993, page: 9, frame: CGRect(x: 0, y: -20, width: 320, height: 80)),
        ContentFeedVisibleRow(ticket: stale, id: 1, page: 1, frame: CGRect(x: 0, y: 0, width: 320, height: 80)),
        ContentFeedVisibleRow(ticket: ticket, id: 2, page: 10, frame: CGRect(x: 0, y: 60, width: 320, height: 80))
    ]
    let row = ContentFeedViewport.firstVisible(samples, viewport: viewport, ticket: ticket)
    #expect(row?.id == 9007199254740993)
    #expect(row?.page == 9)
    for replacement in [
        ContentFeedTicket(generation: 8, board: "tech", sort: "LAST_REPLY", observation: ticket.observation),
        ContentFeedTicket(generation: 7, board: "life", sort: "LAST_REPLY", observation: ticket.observation),
        ContentFeedTicket(generation: 7, board: "tech", sort: "POST_TIME", observation: ticket.observation),
        ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    ] {
        #expect(ContentFeedViewport.firstVisible(samples, viewport: viewport, ticket: replacement) == nil)
    }
    #expect(ContentFeedViewport.firstVisible(samples, viewport: .zero, ticket: ticket) == nil)
}

@Test func feedSheetCancelAndOldOwnerNeverJump() {
    let ticket = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    var sheet = ContentFeedSheet()
    sheet.present(ticket)
    sheet.cancel()
    #expect(sheet.take(4, current: ticket) == nil)
    sheet.present(ticket)
    let other = ContentFeedTicket(generation: 2, board: "a", sort: "LAST_REPLY", observation: ticket.observation)
    #expect(sheet.take(4, current: other) == nil)
    sheet.present(ticket)
    #expect(sheet.take(4, current: ticket) == 4)
    #expect(sheet.take(4, current: ticket) == nil)
}

@Test func feedRailDirectionIsStickyAndComposeKeepsAuthGate() {
    var direction = ContentFeedDirection()
    direction.record(translation: 0)
    direction.record(translation: -40)
    #expect(!direction.expanded)
    direction.record(translation: -40)
    #expect(!direction.expanded)
    direction.record(translation: 0)
    #expect(direction.expanded)
    #expect(ContentFeedCompose.resolve(signedIn: false, board: "tech") == .signIn)
    #expect(ContentFeedCompose.resolve(signedIn: true, board: "tech") == .compose(["boardSlug": .string("tech")]))
    #expect(ContentFeedCompose.resolve(signedIn: true, board: "") == .compose([:]))
}

private func feedSnapshot(append: String = "NotLoading", pages: [Int64] = [4, 5]) -> JSONValue {
    .object(["pagerId": .string("owned"), "placeholdersBefore": .integer(150), "placeholdersAfter": .integer(0),
             "itemCount": .integer(150 + Int64(pages.count)), "totalPages": .integer(20),
             "append": .object(["status": .string(append), "endOfPaginationReached": .bool(false)]),
             "items": .array(pages.enumerated().map { index, page in
                 .object(["summary": .object(["postId": .integer(9007199254740993 + Int64(index))]), "page": .integer(page)])
             })])
}

@Test func feedJumpScrollsLoadedPageAppendsAdjacentAndRetainsRetryTarget() throws {
    var jump = ContentFeedJump()
    let snapshot = feedSnapshot()
    #expect(try jump.request(5, snapshot: snapshot) == .scroll(9007199254740994))
    #expect(jump.pendingPage == nil)
    #expect(try jump.request(6, snapshot: snapshot) == .access(["pagerId": .string("owned"), "index": .integer(151)]))
    #expect(jump.pendingPage == 6)
    #expect(try jump.arrived(snapshot: feedSnapshot(append: "Error")) == nil)
    #expect(jump.pendingPage == 6)
    var unrelated = feedSnapshot(pages: [4, 5, 6]).object!
    unrelated["pagerId"] = .string("retired-pager")
    #expect(try jump.arrived(snapshot: .object(unrelated)) == nil)
    #expect(jump.pendingPage == 6)
    #expect(try jump.request(6, snapshot: feedSnapshot(append: "Error")) == .retry("owned"))
    #expect(try jump.arrived(snapshot: feedSnapshot(pages: [4, 5, 6])) == 9007199254740995)
    #expect(jump.pendingPage == nil)
    #expect(try jump.request(19, snapshot: snapshot) == .replace(19))
    #expect(try jump.request(-1, snapshot: snapshot) == .replace(1))
    #expect(try jump.request(Int64.max, snapshot: snapshot) == .replace(20))
    var exhausted = snapshot.object!
    exhausted["append"] = .object(["status": .string("NotLoading"), "endOfPaginationReached": .bool(true)])
    #expect(try jump.request(6, snapshot: .object(exhausted)) == .replace(6))
    #expect(jump.pendingPage == nil)
}

// Independent HOME-1 reviewer regression, retained verbatim.
@Test func exhaustedAppendMustNotLeaveAnUnreachablePendingTravel() throws {
    func snapshot(end: Bool) -> JSONValue {
        .object(["pagerId": .string("same-pager"), "placeholdersBefore": .integer(0), "placeholdersAfter": .integer(0),
                 "itemCount": .integer(1), "totalPages": .integer(20),
                 "append": .object(["status": .string("NotLoading"), "endOfPaginationReached": .bool(end)]),
                 "items": .array([.object(["summary": .object(["postId": .integer(42)]), "page": .integer(5)])])])
    }
    var jump = ContentFeedJump()
    #expect(try jump.request(6, snapshot: snapshot(end: false)) == .access(["pagerId": .string("same-pager"), "index": .integer(0)]))
    #expect(try jump.arrived(snapshot: snapshot(end: true)) == nil)
    #expect(jump.pendingPage == nil, "A terminal append with no target row must finish or fall back, not retain travel indefinitely")
}

@Test func feedTerminalAppendReplacesMissingPageExactlyOnce() throws {
    var jump = ContentFeedJump()
    _ = try jump.request(6, snapshot: feedSnapshot())
    var terminal = feedSnapshot().object!
    terminal["append"] = .object(["status": .string("NotLoading"), "endOfPaginationReached": .bool(true)])
    #expect(try jump.update(snapshot: .object(terminal)) == .replace(6))
    #expect(jump.pendingPage == nil)
    #expect(try jump.update(snapshot: .object(terminal)) == nil)
}

@Test func feedAppendWaitIsBoundedAtFifteenSecondsWithoutPollingOrRepeatedFallback() throws {
    var now: TimeInterval = 100
    var jump = ContentFeedJump(uptime: { now })
    _ = try jump.request(6, snapshot: feedSnapshot())
    now = 114.999
    #expect(try jump.update(snapshot: feedSnapshot(append: "Loading")) == nil)
    #expect(jump.pendingPage == 6)
    now = 115
    #expect(try jump.update(snapshot: feedSnapshot(append: "Loading")) == .replace(6))
    #expect(jump.pendingPage == nil)
    now = 200
    #expect(try jump.update(snapshot: feedSnapshot()) == nil)
}

@Test func feedTravelRejectsReplacedGenerationBoardSortObservationAndPager() throws {
    let owner = ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    let replacements = [
        ContentFeedTicket(generation: 8, board: "tech", sort: "LAST_REPLY", observation: owner.observation),
        ContentFeedTicket(generation: 7, board: "life", sort: "LAST_REPLY", observation: owner.observation),
        ContentFeedTicket(generation: 7, board: "tech", sort: "POST_TIME", observation: owner.observation),
        ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    ]
    for current in replacements {
        var now: TimeInterval = 0
        var jump = ContentFeedJump(owner: owner, uptime: { now })
        _ = try jump.request(6, snapshot: feedSnapshot())
        let wait = try #require(jump.wait)
        now = 15
        #expect(try jump.timeout(wait, snapshot: feedSnapshot(), current: current) == nil)
        #expect(jump.pendingPage == nil)
        #expect(jump.wait == nil)
        _ = try jump.request(6, snapshot: feedSnapshot())
        #expect(try jump.update(snapshot: feedSnapshot(pages: [4, 5, 6]), current: current) == nil)
        #expect(jump.pendingPage == nil)
    }
    var jump = ContentFeedJump(owner: owner)
    _ = try jump.request(6, snapshot: feedSnapshot())
    var other = feedSnapshot(pages: [4, 5, 6]).object!
    other["pagerId"] = .string("replacement")
    #expect(try jump.update(snapshot: .object(other), current: owner) == nil)
    #expect(jump.pendingPage == nil)
    #expect(jump.wait == nil)
}

@Test func feedErrorRetainsRetryDestinationWithoutTimerOrAutomaticRequests() throws {
    var now: TimeInterval = 0
    var jump = ContentFeedJump(uptime: { now })
    _ = try jump.request(6, snapshot: feedSnapshot())
    let expired = try #require(jump.wait)
    now = 15
    // Even if Error and the deadline race, Error must remain explicitly retryable.
    #expect(try jump.timeout(expired, snapshot: feedSnapshot(append: "Error")) == nil)
    #expect(jump.pendingPage == 6)
    #expect(jump.wait == nil)
    for time in [30.0, 60.0, 120.0] {
        now = time
        #expect(try jump.update(snapshot: feedSnapshot(append: "Error")) == nil)
        #expect(try jump.timeout(expired, snapshot: feedSnapshot()) == nil)
        #expect(jump.pendingPage == 6)
        #expect(jump.wait == nil)
    }
    #expect(try jump.request(6, snapshot: feedSnapshot(append: "Error")) == .retry("owned"))
    let retried = try #require(jump.wait)
    #expect(retried != expired)
    #expect(jump.remaining(retried) == 15)
    now = 134.999
    #expect(try jump.timeout(retried, snapshot: feedSnapshot(append: "Loading")) == nil)
    now = 135
    #expect(try jump.timeout(retried, snapshot: feedSnapshot(append: "Loading")) == .replace(6))
    #expect(jump.pendingPage == nil)
    #expect(jump.wait == nil)
}

@Test func feedArrivalAtDeadlineWinsOverFallbackAndCancelsTimer() throws {
    var now: TimeInterval = 0
    var jump = ContentFeedJump(uptime: { now })
    _ = try jump.request(6, snapshot: feedSnapshot())
    let wait = try #require(jump.wait)
    now = 15
    #expect(try jump.timeout(wait, snapshot: feedSnapshot(pages: [4, 5, 6])) == .scroll(9007199254740995))
    #expect(jump.pendingPage == nil)
    #expect(jump.wait == nil)
    now = 30
    #expect(try jump.timeout(wait, snapshot: feedSnapshot()) == nil)
}

@Test func feedCancelledOrReplacedWaitCannotFinishNewTravel() throws {
    var now: TimeInterval = 0
    var jump = ContentFeedJump(uptime: { now })
    _ = try jump.request(6, snapshot: feedSnapshot())
    let cancelled = try #require(jump.wait)
    jump.cancel()
    #expect(jump.pendingPage == nil)
    #expect(jump.wait == nil)
    now = 100
    #expect(try jump.timeout(cancelled, snapshot: feedSnapshot()) == nil)
    _ = try jump.request(6, snapshot: feedSnapshot())
    let superseded = try #require(jump.wait)
    _ = try jump.request(7, snapshot: feedSnapshot(pages: [5, 6]))
    let current = try #require(jump.wait)
    #expect(superseded != current)
    now = 115
    #expect(try jump.timeout(superseded, snapshot: feedSnapshot(pages: [5, 6])) == nil)
    #expect(jump.pendingPage == 7)
    #expect(jump.wait == current)
    #expect(try jump.timeout(current, snapshot: feedSnapshot(pages: [5, 6])) == .replace(7))
    #expect(try jump.timeout(current, snapshot: feedSnapshot(pages: [5, 6])) == nil)
}

@Test func feedOwnedTravelUsesTheSameTerminalTimeoutAndRetryPolicy() throws {
    let owner = ContentFeedTicket(generation: 7, board: "tech", sort: "LAST_REPLY", observation: UUID())
    var now: TimeInterval = 0
    var jump = ContentFeedJump(owner: owner, uptime: { now })
    _ = try jump.request(6, snapshot: feedSnapshot())
    #expect(try jump.update(snapshot: feedSnapshot(append: "Error"), current: owner) == nil)
    #expect(jump.pendingPage == 6)
    #expect(jump.wait == nil)
    #expect(try jump.request(6, snapshot: feedSnapshot(append: "Error")) == .retry("owned"))
    #expect(try jump.update(snapshot: feedSnapshot(pages: [4, 5, 6]), current: owner) == .scroll(9007199254740995))
    #expect(jump.wait == nil)
    _ = try jump.request(6, snapshot: feedSnapshot())
    var terminal = feedSnapshot().object!
    terminal["append"] = .object(["status": .string("NotLoading"), "endOfPaginationReached": .bool(true)])
    #expect(try jump.update(snapshot: .object(terminal), current: owner) == .replace(6))
    #expect(jump.wait == nil)
    _ = try jump.request(6, snapshot: feedSnapshot())
    let wait = try #require(jump.wait)
    now = 15
    // No observation emission is necessary: the sleeper asks the production timeout helper.
    #expect(try jump.timeout(wait, snapshot: feedSnapshot(), current: owner) == .replace(6))
    #expect(jump.pendingPage == nil)
    #expect(jump.wait == nil)
}

@Test func feedTerminalArrivalPrefersLoadedRowAndInvalidatesItsDeadline() throws {
    var jump = ContentFeedJump()
    _ = try jump.request(6, snapshot: feedSnapshot())
    let wait = try #require(jump.wait)
    var terminal = feedSnapshot(pages: [4, 5, 6]).object!
    terminal["append"] = .object(["status": .string("NotLoading"), "endOfPaginationReached": .bool(true)])
    #expect(try jump.update(snapshot: .object(terminal)) == .scroll(9007199254740995))
    #expect(jump.wait == nil)
    #expect(try jump.timeout(wait, snapshot: feedSnapshot()) == nil)
}
