import Foundation
import Combine

/// View-local scroll intent, not message storage. Samples carry their content
/// identity so a new layout cannot revoke the pre-append follow decision.
struct EditorMessageFollowState {
    struct Scope: Hashable, Sendable {
        let generation: Int
        let uid: Int64
    }
    struct Sample: Equatable, Sendable {
        let scope: Scope
        let lastID: String?
        let top: Double
        let height: Double
        let viewport: Double
    }
    private var previous: Sample?
    private var revoked = false
    private(set) var followsBottom = true
    private(set) var hasNewMessages = false

    mutating func update(_ sample: Sample) -> Bool {
        guard !revoked, sample.top.isFinite, sample.height.isFinite,
              sample.viewport.isFinite, sample.height >= 0, sample.viewport > 0,
              previous == nil || previous?.scope == sample.scope else { return false }
        let old = previous
        let changed = old?.lastID != sample.lastID
        let resized = old?.height != sample.height || old?.viewport != sample.viewport
        // Offset-only movement (including public programmatic scrolls) is reading
        // intent. Content/viewport growth by itself must not turn following off.
        if let old, !changed, old.viewport == sample.viewport, abs(old.top - sample.top) > 0.5 {
            followsBottom = sample.top + sample.height - sample.viewport <= 80
            if followsBottom { hasNewMessages = false }
        }
        if changed, old?.lastID != nil, sample.lastID != nil, !followsBottom { hasNewMessages = true }
        previous = sample
        return sample.lastID != nil && followsBottom && (old == nil || changed || resized)
    }

    mutating func resume() {
        guard !revoked else { return }
        followsBottom = true
        hasNewMessages = false
    }

    mutating func activate() { revoked = false }
    mutating func revoke() { revoked = true }
}

/// Keep raw scroll samples outside SwiftUI's published state. Only a change to
/// the visible return affordance invalidates the message history view.
@MainActor final class EditorMessageFollowObservation: ObservableObject {
    enum Presentation: Equatable { case following, returnToLatest, newMessages }
    @Published private(set) var presentation = Presentation.following
    @Published private(set) var observation = UUID()
    private var state = EditorMessageFollowState()
    private var scope: EditorMessageFollowState.Scope?
    private var active = true

    func update(_ sample: EditorMessageFollowState.Sample, observation: UUID) -> Bool {
        guard active, observation == self.observation,
              scope == nil || scope == sample.scope else { return false }
        scope = sample.scope
        let scroll = state.update(sample)
        publishPresentation()
        return scroll
    }

    func returnTarget(_ currentID: String?, scope: EditorMessageFollowState.Scope, observation: UUID) -> String? {
        guard active, observation == self.observation, self.scope == scope else { return nil }
        state.resume()
        publishPresentation()
        return currentID
    }

    func activate() { active = true; state.activate() }
    func revoke() { active = false; state.revoke(); observation = UUID() }

    func makeReturnAction(
        targetID: String,
        scope: EditorMessageFollowState.Scope,
        observation: UUID,
        scrollTo: @escaping (String) -> Void
    ) -> () -> Void {
        { [weak self] in
            guard let self,
                  let target = returnTarget(targetID, scope: scope, observation: observation) else { return }
            scrollTo(target)
        }
    }

    private func publishPresentation() {
        let next: Presentation = state.followsBottom ? .following : (state.hasNewMessages ? .newMessages : .returnToLatest)
        if presentation != next { presentation = next }
    }
}
