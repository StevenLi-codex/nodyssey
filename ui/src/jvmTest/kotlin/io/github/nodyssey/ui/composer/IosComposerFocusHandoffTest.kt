package io.github.nodyssey.ui.composer

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.ui.text.TextRange
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull

class IosComposerFocusHandoffTest {
    @Test
    fun `marked draft is retained before focus release and preview callback`() {
        val draft = markedDraft()
        val events = mutableListOf<String>()
        val owner = runCatching {
            Class.forName("io.github.nodyssey.ui.composer.ComposerFocusHandoffKt")
        }.getOrNull()
        assertNotNull(owner, "Missing iOS handoff: retain marked text before clearing focus")
        val handoff = owner.declaredMethods.single { it.name == "leaveIosComposerInput" }
        handoff.invoke(
            null,
            listOf(draft),
            {
                assertEquals(null, draft.composition, "Resolve composition before ending the input session")
                assertEquals("草稿 nihao", draft.text.toString())
                events += "clear"
            },
            { events += "hide" },
            {
                events += "preview:${draft.text}"
                assertEquals(TextRange(8), draft.selection)
            },
        )
        assertEquals(listOf("clear", "hide", "preview:草稿 nihao"), events)
    }

    @Test
    fun `all marked fields are committed before clearing focus with selections intact`() {
        val title = markedDraft(TextRange(7, 4))
        val body = markedDraft(TextRange(5))
        val untouched = TextFieldState("unchanged", TextRange(2))
        val events = mutableListOf<String>()
        observeEdits(title) { events += "title" }
        observeEdits(body) { events += "body" }
        observeEdits(untouched) { events += "unexpected edit" }
        leaveIosComposerInput(
            listOf(title, untouched, body),
            clearFocus = {
                assertEquals(null, title.composition)
                assertEquals(null, body.composition)
                events += "clear"
            },
            hideKeyboard = { events += "hide" },
            action = {
                assertEquals("草稿 nihao", title.text.toString())
                assertEquals("草稿 nihao", body.text.toString())
                assertEquals(TextRange(7, 4), title.selection)
                assertEquals(TextRange(5), body.selection)
                events += "action"
            },
        )
        assertEquals(listOf("title", "body", "clear", "hide", "action"), events)
    }

    @Test
    fun `unmarked draft produces no edit notification and action runs once inline`() {
        val draft = TextFieldState("draft", TextRange(4, 1))
        val events = mutableListOf<String>()
        observeEdits(draft) { events += "edit" }
        val thread = Thread.currentThread()
        leaveIosComposerInput(
            listOf(draft),
            { events += "clear" },
            { events += "hide" },
            {
                assertEquals(thread, Thread.currentThread())
                assertEquals(TextRange(4, 1), draft.selection)
                events += "action"
            },
        )
        assertEquals(listOf("clear", "hide", "action"), events)
    }

    @Test
    fun `platform selection leaves non iOS input untouched and retains legacy preview hide`() {
        assertFalse(iosComposerFocusHandoff, "JVM and Android must retain their old input behavior")
        val owner = Class.forName("io.github.nodyssey.ui.composer.ComposerFocusHandoffKt")
        val dispatch = owner.declaredMethods.singleOrNull { it.name == "runComposerInputAction" }
        assertNotNull(dispatch, "Missing iOS-only platform dispatch")
        for (ios in listOf(false, true)) {
            for (legacyHide in listOf(false, true)) {
                val draft = markedDraft()
                val events = mutableListOf<String>()
                dispatch.invoke(null, listOf(draft), { events += "clear" }, { events += "hide" }, {
                    assertEquals(if (ios) null else TextRange(3, 8), draft.composition)
                    events += "action"
                }, ios, legacyHide)
                assertEquals(
                    if (ios) {
                        listOf("clear", "hide", "action")
                    } else if (legacyHide) {
                        listOf("hide", "action")
                    } else {
                        listOf("action")
                    },
                    events,
                )
            }
        }
    }

    private fun observeEdits(state: TextFieldState, onEdit: () -> Unit) {
        val listenerType = state.javaClass.declaredClasses.single { it.simpleName == "NotifyImeListener" }
        val listener = Proxy.newProxyInstance(listenerType.classLoader, arrayOf(listenerType)) { _, method, _ ->
            when (method.name) {
                "onChange" -> {
                    onEdit()
                    null
                }

                "hashCode" -> 0

                "equals" -> false

                else -> null
            }
        }
        state.javaClass.methods.single { it.name.startsWith("addNotifyImeListener$") }.invoke(state, listener)
    }

    /** Drive the resolved Compose buffer just as an IME does, not a second draft implementation. */
    private fun markedDraft(selection: TextRange = TextRange(8)): TextFieldState {
        val state = TextFieldState("草稿 nihao", selection)
        // Publish through Compose's real buffer path. Public edits are the behavior under
        // test, so do not use them to create the IME fixture.
        val mark: (Any) -> Unit = { buffer ->
            buffer.javaClass.methods.single { it.name.startsWith("setComposition$") && it.parameterCount == 3 }
                .invoke(buffer, 3, 8, null)
        }
        state.javaClass.methods.single { it.name.startsWith("editWithNoSideEffects$") }
            .invoke(state, mark)
        assertEquals(TextRange(3, 8), state.composition)
        return state
    }
}
