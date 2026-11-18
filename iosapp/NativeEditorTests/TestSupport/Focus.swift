import SwiftUI
// Only UIKit input focus is substituted. Lifecycle tests execute the production
// EditorViewModel, EditorSession, draft queue and transport calls unchanged.
@MainActor final class EditorFocus {
    var awaitingReplyEmojiMeasurement = false
    var inputs: [any EditorInput] = []
    func handoff(preservingInput: Bool = false, _ action: () -> Void) { EditorHandoff.perform(inputs, preservingInput: preservingInput, action: action) }
    func applyReplyInputMode(_ mode: EditorReplyInputMode) {}
    func applyBody(_ buffer: EditorBuffer) {}
    func refocus() {}
}
