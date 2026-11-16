import SwiftUI

#if !FOUNDATION_EDITOR_TESTS
/// Presentation only: hints never become editor text, selection, or draft content.
/// Keep the same input owner mounted when the buffer changes or becomes empty.
struct NativeComposerField: View {
    @Binding var buffer: EditorBuffer
    let focus: EditorFocus
    var isTitle = false
    let accessibilityLabel: String
    let hint: String

    var body: some View {
        MarkedTextEditor(buffer: $buffer, focus: focus, isTitle: isTitle, accessibilityLabel: accessibilityLabel)
            .overlay(alignment: .topLeading) {
                // UIKit publishes its complete text, including the current marked
                // run, through the existing snapshot binding. Do not trim it:
                // whitespace is still input, and an IME owns its composing text.
                if buffer.text.isEmpty {
                    Text(hint)
                        .font(isTitle ? .headline : .body)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        // Match the existing text-container inset + line padding.
                        .padding(.horizontal, 9)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

func PCL(_ key: String) -> String {
    NSLocalizedString(key, tableName: "PostComposer", bundle: .main, comment: "")
}
#endif
