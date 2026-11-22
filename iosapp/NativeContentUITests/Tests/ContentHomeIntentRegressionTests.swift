import Foundation
import Testing
@testable import NativeContentState

@Test func homeJumpRejectsIntentFromAnotherBoardSortOrGeneration() {
    let a = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    for b in [ContentHomePageJumpScope(generation: 1, board: "b", sort: "LAST_REPLY"),
              ContentHomePageJumpScope(generation: 2, board: "a", sort: "LAST_REPLY"),
              ContentHomePageJumpScope(generation: 1, board: "a", sort: "POST_TIME")] {
        var pending: ContentHomePageJumpIntent? = .init(scope: a)
        #expect(ContentHomePageJumpIntent.take(&pending, current: a, owner: nil) == nil)
        #expect(pending != nil)
        let next = ContentFeedTicket(generation: b.generation, board: b.board, sort: b.sort, observation: UUID())
        #expect(ContentHomePageJumpIntent.take(&pending, current: b, owner: next) == nil)
        #expect(pending == nil)
    }
}

@Test func homeJumpKeepsLegalLoadingIntentAndConsumesItOnce() {
    let scope = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    var pending: ContentHomePageJumpIntent? = .init(scope: scope)
    #expect(ContentHomePageJumpIntent.take(&pending, current: scope, owner: nil) == nil)
    #expect(pending != nil)
    let owner = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    #expect(ContentHomePageJumpIntent.take(&pending, current: scope, owner: owner) == owner)
    #expect(pending == nil)
    #expect(ContentHomePageJumpIntent.take(&pending, current: scope, owner: owner) == nil)
}

@Test func homeJumpOldSheetCannotConsumeNewBoardPresentation() {
    let a = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let b = ContentFeedTicket(generation: 2, board: "b", sort: "LAST_REPLY", observation: UUID())
    let scope = ContentHomePageJumpScope(generation: b.generation, board: b.board, sort: b.sort)
    var sheet = ContentHomePageJumpSheet()
    sheet.present(a)
    let presented = sheet.presentation
    sheet.cancel()
    sheet.present(b)
    let rejected = sheet.take(7, presented: presented, current: b, scope: scope)
    #expect(rejected == nil)
    #expect(sheet.owner == b)
    let current = sheet.presentation
    let accepted = sheet.take(3, presented: current, current: b, scope: scope)
    #expect(accepted == 3)
}

@Test func homeSwipeExactReviewerReorderCannotRearmSameGesture() {
    let a = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "b", "c"], isHomeRoot: true)
    let reordered = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "c", "b"], isHomeRoot: true)
    func context(_ owner: ContentFeedBoardSwipeOwner?) -> ContentFeedBoardSwipeContext {
        .init(scope: owner?.scope ?? a.scope, current: owner)
    }
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: context(a), x: -18, y: 2, rightToLeft: false, now: 1)
    trace.revoke()
    trace.change(gesture: gesture1, context: context(reordered), x: -68, y: 4)
    #expect(trace.finish(gesture: gesture1, context: context(reordered), x: -90, y: 5, now: 1) == nil)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: context(reordered), x: -18, y: 2, rightToLeft: false, now: 2)
    #expect(trace.finish(gesture: gesture2, context: context(reordered), x: -90, y: 5, now: 2) == "c")
    let gesture3 = UUID()
    trace.begin(gesture: gesture3, context: context(a), x: -18, y: 2, rightToLeft: false, now: 3)
    trace.change(gesture: gesture3, context: context(a), x: -68, y: 4)
    #expect(trace.finish(gesture: gesture3, context: context(a), x: -90, y: 5, now: 3) == "b")
}

@Test func homeSwipeVerticalGateCycleStaysRejectedUntilRealCancellation() {
    let owner = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "b", "c"], isHomeRoot: true)
    let scope = owner.scope
    func context(_ owner: ContentFeedBoardSwipeOwner?) -> ContentFeedBoardSwipeContext {
        .init(scope: owner?.scope ?? scope, current: owner)
    }
    var trace = ContentFeedBoardSwipeTrace()
    let gesture1 = UUID()
    trace.begin(gesture: gesture1, context: context(owner), x: -2, y: 18, rightToLeft: false, now: 1)
    trace.revoke()
    trace.change(gesture: gesture1, context: context(owner), x: -68, y: 25)
    #expect(trace.finish(gesture: gesture1, context: context(owner), x: -90, y: 30, now: 1) == nil)
    let gesture2 = UUID()
    trace.begin(gesture: gesture2, context: context(owner), x: -18, y: 2, rightToLeft: false, now: 2)
    trace.revoke()
    trace.cancel(gesture: gesture2, now: 2)
    let gesture3 = UUID()
    trace.begin(gesture: gesture3, context: context(owner), x: -18, y: 2, rightToLeft: false, now: 3)
    #expect(trace.finish(gesture: gesture3, context: context(owner), x: -90, y: 5, now: 3) == "b")
}

@Test func homeJumpOldActionsLeaveReopenedOrReplacementSheetIntact() {
    let scope = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    let ticket = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let replacement = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    for nextTicket in [ticket, replacement] {
        var sheet = ContentHomePageJumpSheet()
        sheet.present(ticket)
        let old = sheet.presentation
        // Cancel and the system binding share this dismissal admission.
        let didDismiss = sheet.dismiss(old, current: ticket, scope: scope)
        #expect(didDismiss)
        #expect(sheet.presentation == nil)
        sheet.present(nextTicket)
        let current = sheet.presentation
        #expect(current?.id != old?.id)
        let staleDismiss = sheet.dismiss(old, current: nextTicket, scope: scope)
        let missingDismiss = sheet.dismiss(nil, current: nextTicket, scope: scope)
        let staleTake = sheet.take(7, presented: old, current: nextTicket, scope: scope)
        #expect(!staleDismiss)
        #expect(!missingDismiss)
        #expect(staleTake == nil)
        #expect(sheet.presentation == current)
        let currentTake = sheet.take(3, presented: current, current: nextTicket, scope: scope)
        #expect(currentTake == 3)
        #expect(sheet.presentation == nil)
    }
}

@Test func homeJumpActionsMustAlsoMatchLiveScopeAndObservation() {
    let scope = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    let differentSort = ContentHomePageJumpScope(generation: 1, board: "a", sort: "POST_TIME")
    let ticket = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let replacement = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    var sheet = ContentHomePageJumpSheet()
    sheet.present(ticket)
    let current = sheet.presentation
    let staleObservationDismiss = sheet.dismiss(current, current: replacement, scope: scope)
    let staleScopeTake = sheet.take(7, presented: current, current: ticket, scope: differentSort)
    #expect(!staleObservationDismiss)
    #expect(staleScopeTake == nil)
    #expect(sheet.presentation == current)
    let currentDismiss = sheet.dismiss(current, current: ticket, scope: scope)
    #expect(currentDismiss)
}

@Test func homeSwipeRechecksScopeAndObservationEvenWithoutLifecycleCallbacks() {
    let scope = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    let differentSort = ContentHomePageJumpScope(generation: 1, board: "a", sort: "POST_TIME")
    let ticket = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let replacement = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let context = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "b", "c"], isHomeRoot: true)
    let first = context.admitted(scope: scope, ticket: ticket)
    let notInstalled = context.admitted(scope: differentSort, ticket: ticket)
    let next = context.admitted(scope: scope, ticket: replacement)
    #expect(notInstalled == nil)
    #expect(next != nil)
    func swipeContext(_ owner: ContentFeedBoardSwipeOwner?) -> ContentFeedBoardSwipeContext {
        .init(scope: first?.scope ?? context.scope, current: owner)
    }
    for changed in [notInstalled, next] {
        var trace = ContentFeedBoardSwipeTrace()
        let gesture1 = UUID()
        trace.begin(gesture: gesture1, context: swipeContext(first), x: -18, y: 2, rightToLeft: false, now: 1)
        trace.change(gesture: gesture1, context: swipeContext(changed), x: -68, y: 4)
        #expect(trace.finish(gesture: gesture1, context: swipeContext(changed), x: -90, y: 5, now: 1) == nil)
        let gesture2 = UUID()
        trace.begin(gesture: gesture2, context: swipeContext(first), x: -18, y: 2, rightToLeft: false, now: 2)
        #expect(trace.finish(gesture: gesture2, context: swipeContext(first), x: -90, y: 5, now: 2) == "b")
    }
}

@Test func homeSwipeBlockedFirstSampleCannotBeRetargetedAfterGateClears() {
    let scope = ContentHomePageJumpScope(generation: 1, board: "a", sort: "LAST_REPLY")
    let ticket = ContentFeedTicket(generation: 1, board: "a", sort: "LAST_REPLY", observation: UUID())
    let context = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "b", "c"], isHomeRoot: true)
    let menuOpen = ContentFeedBoardSwipeOwner(generation: 1, identityEpoch: "epoch", board: "a",
        orderedBoards: ["", "a", "b", "c"], isHomeRoot: false)
    let admitted = context.admitted(scope: scope, ticket: ticket)
    let open = ContentFeedBoardSwipeContext(scope: admitted?.scope ?? context.scope, current: admitted)
    for blocked in [ContentFeedBoardSwipeContext(scope: open.scope, current: context.admitted(scope: scope, ticket: nil)),
                    ContentFeedBoardSwipeContext(scope: menuOpen.scope, current: menuOpen.admitted(scope: scope, ticket: ticket))] {
        #expect(blocked.current == nil)
        var trace = ContentFeedBoardSwipeTrace()
        let gesture1 = UUID()
        trace.begin(gesture: gesture1, context: blocked, x: -18, y: 2, rightToLeft: false, now: 1)
        trace.change(gesture: gesture1, context: open, x: -68, y: 4)
        #expect(trace.finish(gesture: gesture1, context: open, x: -90, y: 5, now: 1) == nil)
        let gesture2 = UUID()
        trace.begin(gesture: gesture2, context: blocked, x: -18, y: 2, rightToLeft: false, now: 2)
        trace.cancel(gesture: gesture2, now: 2)
        let gesture3 = UUID()
        trace.begin(gesture: gesture3, context: open, x: -18, y: 2, rightToLeft: false, now: 3)
        #expect(trace.finish(gesture: gesture3, context: open, x: -90, y: 5, now: 3) == "b")
    }
}
