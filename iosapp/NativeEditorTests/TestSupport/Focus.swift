import SwiftUI
// Only UIKit input focus is substituted. Lifecycle tests execute the production
// EditorViewModel, EditorSession, draft queue and transport calls unchanged.
@MainActor final class EditorFocus {
    func handoff(_ action: () -> Void) { action() }
    func refocus() {}
}
