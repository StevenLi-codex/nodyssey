package io.github.nodyssey.ui.composer

import androidx.compose.foundation.text.input.TextFieldState
import io.github.plaza.designsys.editor.MarkdownEditorState
import io.github.plaza.designsys.editor.insertText

/** Preserve raw preedit before the new dialog takes focus. Does not resolve an IME candidate. */
internal fun prepareManualPhrasePicker(
    editor: MarkdownEditorState,
    fields: List<TextFieldState>,
    handoff: () -> Unit,
) {
    fields.forEach { field ->
        if (field.composition != null) {
            val raw = field.text.toString()
            val selection = field.selection
            field.edit {
                replace(0, length, raw)
                this.selection = selection
            }
        }
    }
    editor.closePanels()
    handoff()
}

/** Deliberately has no publishing/upload dependency. Uses the original editor's selection primitive. */
internal fun insertManualPhrase(body: TextFieldState, phrase: String) {
    body.edit {
        val caret = selection.min + phrase.length
        insertText(phrase)
        // Reversed selections otherwise leave the new phrase selected and the next keystroke erases it.
        placeCursorBeforeCharAt(caret)
    }
}
