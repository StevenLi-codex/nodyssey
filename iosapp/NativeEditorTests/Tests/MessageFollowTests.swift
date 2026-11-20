import Testing
@testable import NativeEditor

struct MessageFollowTests {
    @Test func appendWhileReadingHistoryDoesNotFollow() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        let initialFollow = state.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700))
        #expect(initialFollow)
        let decision2 = !state.update(.init(scope: scope, lastID: "60", top: -700, height: 5000, viewport: 700))
        #expect(decision2)
        let decision3 = !state.update(.init(scope: scope, lastID: "61", top: -700, height: 5100, viewport: 700))
        #expect(decision3)
        #expect(state.hasNewMessages)
        #expect(!state.followsBottom)
    }

    @Test func nearBottomAppendUsesPreAppendIntent() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        let initialFollow = state.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700))
        #expect(initialFollow)
        _ = state.update(.init(scope: scope, lastID: "60", top: -4280, height: 5000, viewport: 700))
        // New layout is now far from bottom; it must not first revoke intent.
        let decision5 = state.update(.init(scope: scope, lastID: "61", top: -4280, height: 5400, viewport: 700))
        #expect(decision5)
        #expect(state.followsBottom)
    }

    @Test func layoutGrowthAndContainerChangesPreserveIntent() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = state.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700))
        _ = state.update(.init(scope: scope, lastID: "60", top: -4300, height: 5000, viewport: 700))
        let decision6 = state.update(.init(scope: scope, lastID: "60", top: -4300, height: 5300, viewport: 700))
        #expect(decision6)
        let decision7 = state.update(.init(scope: scope, lastID: "60", top: -4300, height: 5300, viewport: 400))
        #expect(decision7)
        #expect(state.followsBottom)
    }

    @Test func returningExplicitlyRearmsFollowAndClearsNotice() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = state.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700))
        _ = state.update(.init(scope: scope, lastID: "60", top: -700, height: 5000, viewport: 700))
        _ = state.update(.init(scope: scope, lastID: "61", top: -700, height: 5100, viewport: 700))
        state.resume()
        #expect(!state.hasNewMessages)
        #expect(state.followsBottom)
        _ = state.update(.init(scope: scope, lastID: "61", top: -4400, height: 5100, viewport: 700))
        let decision8 = state.update(.init(scope: scope, lastID: "62", top: -4400, height: 5200, viewport: 700))
        #expect(decision8)
    }

    @Test func staleGenerationUIDAndRevokedSamplesCannotMoveCurrentOwner() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = state.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700))
        let decision9 = !state.update(.init(scope: .init(generation: 2, uid: 42), lastID: "61", top: 0, height: 5100, viewport: 700))
        #expect(decision9)
        let decision10 = !state.update(.init(scope: .init(generation: 1, uid: 43), lastID: "61", top: 0, height: 5100, viewport: 700))
        #expect(decision10)
        state.revoke()
        let decision11 = !state.update(.init(scope: scope, lastID: "61", top: 0, height: 5100, viewport: 700))
        #expect(decision11)
        state.activate()
        let decision12 = state.update(.init(scope: scope, lastID: "61", top: 0, height: 5100, viewport: 700))
        #expect(decision12)
    }

    @Test func emptyInvalidAndRepeatedSamplesDoNotIssueScrollLoops() {
        var state = EditorMessageFollowState()
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        let decision13 = !state.update(.init(scope: scope, lastID: nil, top: 0, height: 32, viewport: 700))
        #expect(decision13)
        let decision14 = !state.update(.init(scope: scope, lastID: "60", top: .nan, height: 5000, viewport: 700))
        #expect(decision14)
        let first = EditorMessageFollowState.Sample(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700)
        let decision15 = state.update(first)
        #expect(decision15)
        let decision16 = !state.update(first)
        #expect(decision16)
    }

    @MainActor @Test func geometryOnlySamplesDoNotPublishViewChanges() {
        let owner = EditorMessageFollowObservation()
        let observation = owner.observation
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        var publications = 0
        let subscription = owner.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        #expect(owner.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700), observation: observation))
        for top in [-700.0, -715, -730, -745] {
            let scroll = owner.update(.init(scope: scope, lastID: "60", top: top, height: 5000, viewport: 700), observation: observation)
            #expect(!scroll)
        }
        #expect(publications == 1)
        #expect(owner.presentation == .returnToLatest)
        let scroll = owner.update(.init(scope: scope, lastID: "61", top: -745, height: 5100, viewport: 700), observation: observation)
        #expect(!scroll)
        #expect(publications == 2)
        #expect(owner.presentation == .newMessages)
    }

    @MainActor @Test func currentRenderReturnDoesNotWaitForTailGeometryAndRearmsFollow() {
        let owner = EditorMessageFollowObservation()
        let observation = owner.observation
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = owner.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700), observation: observation)
        _ = owner.update(.init(scope: scope, lastID: "60", top: -700, height: 5000, viewport: 700), observation: observation)
        _ = owner.update(.init(scope: scope, lastID: "61", top: -700, height: 5100, viewport: 700), observation: observation)
        // A new render may already show 62 before its geometry is accepted.
        var scrolled: [String] = []
        let action = owner.makeReturnAction(
            targetID: "62", scope: scope, observation: observation, scrollTo: { scrolled.append($0) })
        action()
        #expect(scrolled == ["62"])
        #expect(owner.presentation == .following)
        _ = owner.update(.init(scope: scope, lastID: "62", top: -4500, height: 5200, viewport: 700), observation: observation)
        let scroll = owner.update(.init(scope: scope, lastID: "63", top: -4500, height: 5300, viewport: 700), observation: observation)
        #expect(scroll)
    }

    @MainActor @Test func temporaryDepartureRejectsLateFramesAndOldActionsAcrossReappearance() {
        let owner = EditorMessageFollowObservation()
        let first = owner.observation
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = owner.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700), observation: first)
        _ = owner.update(.init(scope: scope, lastID: "60", top: -700, height: 5000, viewport: 700), observation: first)
        owner.revoke()
        let second = owner.observation
        let append = EditorMessageFollowState.Sample(scope: scope, lastID: "61", top: -700, height: 5100, viewport: 700)
        let hidden = owner.update(append, observation: second)
        #expect(!hidden)
        let hiddenAction = owner.returnTarget("61", scope: scope, observation: second)
        #expect(hiddenAction == nil)
        owner.activate()
        let old = owner.update(append, observation: first)
        #expect(!old)
        let oldAction = owner.returnTarget("60", scope: scope, observation: first)
        #expect(oldAction == nil)
        #expect(owner.presentation == .returnToLatest)
        let resumed = owner.update(append, observation: second)
        #expect(!resumed)
        #expect(owner.presentation == .newMessages)
        for scope in [EditorMessageFollowState.Scope(generation: 2, uid: 42), .init(generation: 1, uid: 43)] {
            let wrongAction = owner.returnTarget("61", scope: scope, observation: second)
            #expect(wrongAction == nil)
        }
        #expect(owner.presentation == .newMessages)
    }

    @MainActor @Test func retainedRenderedReturnActionCannotClearNewNoticeAfterReactivation() {
        let owner = EditorMessageFollowObservation()
        let firstObservation = owner.observation
        let scope = EditorMessageFollowState.Scope(generation: 1, uid: 42)
        _ = owner.update(.init(scope: scope, lastID: "60", top: 0, height: 5000, viewport: 700), observation: firstObservation)
        _ = owner.update(.init(scope: scope, lastID: "60", top: -700, height: 5000, viewport: 700), observation: firstObservation)
        #expect(owner.presentation == .returnToLatest)

        var scrolled: [String] = []
        let oldRenderedAction = owner.makeReturnAction(
            targetID: "60", scope: scope, observation: firstObservation, scrollTo: { scrolled.append($0) })

        owner.revoke()
        owner.activate()
        let resumedObservation = owner.observation
        _ = owner.update(.init(scope: scope, lastID: "61", top: -700, height: 5100, viewport: 700), observation: resumedObservation)
        #expect(owner.presentation == .newMessages)

        oldRenderedAction()

        #expect(scrolled.isEmpty)
        #expect(owner.presentation == .newMessages)
        let appendWouldFollow = owner.update(
            .init(scope: scope, lastID: "62", top: -700, height: 5200, viewport: 700), observation: resumedObservation)
        #expect(!appendWouldFollow)
        #expect(owner.presentation == .newMessages)
    }
}
