package io.github.nodyssey.ui.composer

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.ui.text.TextRange
import io.github.plaza.designsys.editor.MarkdownEditorState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class ManualPhraseInsertionTest {
    @Test
    fun `opening preserves marked text before focus handoff and insertion replaces only selection`() {
        val body = TextFieldState("> quote\n拼音tail", TextRange(10, 8))
        val title = TextFieldState("标题", TextRange(2))
        val method = TextFieldState::class.java.methods.single { it.name == "editWithNoSideEffects\$foundation" }
        for (state in listOf(body, title)) {
            method.invoke(state, { buffer: androidx.compose.foundation.text.input.TextFieldBuffer ->
                buffer.javaClass.methods.single { it.name == "setComposition\$foundation" }
                    .invoke(buffer, 0, 2, emptyList<Any>())
                Unit
            })
            assertNotNull(state.composition)
        }
        val editor = MarkdownEditorState(emojiOpen = true)
        prepareManualPhrasePicker(editor, listOf(title, body)) {
            assertNull(title.composition)
            assertNull(body.composition)
            assertEquals("> quote\n拼音tail", body.text.toString())
            assertEquals(TextRange(10, 8), body.selection)
        }
        assertFalse(editor.emojiOpen)
        insertManualPhrase(body, "hello")
        assertEquals("> quote\nhellotail", body.text.toString())
        assertEquals(TextRange(13), body.selection)
    }
}
