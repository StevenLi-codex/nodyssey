package io.github.nodyssey.ui.composer

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.ui.text.TextRange
import io.github.plaza.designsys.editor.EditorAction
import io.github.plaza.designsys.editor.MarkdownEditorState
import io.github.plaza.designsys.editor.dispatch
import io.github.plaza.designsys.editor.emojiPanelScope
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ComposerPanelTransitionTest {
    @Test
    fun `emoji opens only after iOS handoff and closes without another handoff`() {
        val title = markedDraft()
        val body = markedDraft()
        val editor = MarkdownEditorState()
        val events = mutableListOf<String>()
        val beforePanel = {
            assertFalse(editor.emojiOpen)
            runComposerInputAction(
                states = listOf(title, body),
                clearFocus = {
                    assertEquals(null, title.composition)
                    assertEquals(null, body.composition)
                    assertFalse(editor.emojiOpen, "The panel must not be visible at focus release")
                    events += "clear"
                },
                hideKeyboard = { events += "hide" },
                action = {},
                ios = true,
                hideOnOtherPlatforms = false,
            )
        }
        dispatchEmoji(editor, body, beforePanel) {
            // This is the legacy hide path, not the iOS callback.
            assertEquals(null, body.composition, "Commit marked input before opening the panel")
            events += "legacy hide"
        }
        assertTrue(editor.emojiOpen)
        assertEquals(listOf("clear", "hide"), events)
        assertEquals("草稿 nihao", title.text.toString())
        assertEquals("草稿 nihao", body.text.toString())
        assertEquals(TextRange(7, 4), body.selection)

        editor.emojiPanelScopeForTest(body)
        dispatchEmoji(editor, body, beforePanel) { events += "unexpected hide" }
        assertFalse(editor.emojiOpen)
        assertEquals(listOf("clear", "hide"), events)
        assertEquals("草稿 !nihao", body.text.toString())
    }

    @Test
    fun `message format opens after handoff then field focus closes panels without draft loss`() {
        val draft = markedDraft()
        val editor = MarkdownEditorState()
        val events = mutableListOf<String>()
        val beforePanel = {
            runComposerInputAction(
                states = listOf(draft),
                clearFocus = {
                    if (events.isEmpty()) assertFalse(editor.formatOpen)
                    assertFalse(editor.emojiOpen)
                    assertEquals(null, draft.composition)
                    events += "clear"
                },
                hideKeyboard = { events += "hide" },
                action = {},
                ios = true,
                hideOnOtherPlatforms = false,
            )
        }
        editor.toggleFormat(beforePanel)
        assertEquals(null, draft.composition, "Format panel must commit raw marked text before it opens")
        assertTrue(editor.formatOpen)
        assertEquals(listOf("clear", "hide"), events)
        editor.toggleFormat(beforePanel)
        assertFalse(editor.formatOpen)
        assertEquals(listOf("clear", "hide"), events)
        editor.toggleFormat(beforePanel)
        dispatchEmoji(editor, draft, beforePanel) { error("Unexpected legacy hide") }
        assertTrue(editor.emojiOpen)
        assertFalse(editor.formatOpen)
        editor.closePanels() // The same transition as tapping back into any draft field.
        assertFalse(editor.emojiOpen)
        assertFalse(editor.formatOpen)
        assertEquals("草稿 nihao", draft.text.toString())
        assertEquals(TextRange(7, 4), draft.selection)
        assertEquals(listOf("clear", "hide", "clear", "hide", "clear", "hide"), events)
    }

    @Test
    fun `default panels preserve non iOS composition and legacy keyboard timing`() {
        assertFalse(iosComposerFocusHandoff)
        val draft = markedDraft()
        val editor = MarkdownEditorState()
        val events = mutableListOf<String>()
        editor.dispatch(EditorAction.EMOJI, draft, {}, {}, {}, hideKeyboard = {
            assertTrue(editor.emojiOpen, "Default behavior hides after opening")
            assertEquals(TextRange(3, 8), draft.composition)
            events += "hide"
        })
        editor.dispatch(EditorAction.EMOJI, draft, {}, {}, {}, hideKeyboard = { error("Closing must not hide") })
        editor.toggleFormat()
        assertTrue(editor.formatOpen)
        assertEquals(TextRange(3, 8), draft.composition)
        editor.closePanels()
        assertEquals("草稿 nihao", draft.text.toString())
        assertEquals(listOf("hide"), events)
    }

    private fun dispatchEmoji(
        editor: MarkdownEditorState,
        body: TextFieldState,
        beforePanel: () -> Unit,
        hideKeyboard: () -> Unit,
    ) {
        editor.dispatch(EditorAction.EMOJI, body, {}, {}, {}, beforePanel, hideKeyboard)
    }

    private fun MarkdownEditorState.emojiPanelScopeForTest(body: TextFieldState) {
        // Insert at a caret without losing any of the raw IME text retained by the handoff.
        body.edit { selection = TextRange(3) }
        emojiPanelScope(body, pictures = null).onInsert("!")
    }

    private fun markedDraft(): TextFieldState {
        val state = TextFieldState("草稿 nihao", TextRange(7, 4))
        val mark: (Any) -> Unit = { buffer ->
            buffer.javaClass.methods.single { it.name.startsWith("setComposition$") && it.parameterCount == 3 }
                .invoke(buffer, 3, 8, null)
        }
        state.javaClass.methods.single { it.name.startsWith("editWithNoSideEffects$") }.invoke(state, mark)
        assertEquals(TextRange(3, 8), state.composition)
        return state
    }
}
