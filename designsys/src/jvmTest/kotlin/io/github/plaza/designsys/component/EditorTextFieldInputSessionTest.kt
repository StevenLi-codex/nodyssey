package io.github.plaza.designsys.component

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusManager
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.PlatformTextInputInterceptor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.v2.runComposeUiTest
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import io.github.plaza.designsys.editor.InlinePicture
import io.github.plaza.designsys.editor.InlinePictures
import kotlinx.coroutines.awaitCancellation
import kotlin.test.Test
import kotlin.test.assertEquals

class EditorTextFieldInputSessionTest {
    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `first and last sticker do not restart the platform input session`() = runComposeUiTest {
        val state = TextFieldState("plain ")
        var starts = 0
        var cancellations = 0
        lateinit var focusManager: FocusManager
        // Observe the real BasicTextField input coroutine, not just focus semantics. A focused
        // field can cancel and replace its IME session when its output transformation changes.
        val interceptor = PlatformTextInputInterceptor { _, _ ->
            starts++
            try {
                awaitCancellation()
            } finally {
                cancellations++
            }
        }
        val pictures = InlinePictures(
            find = { source ->
                val at = source.indexOf(":sticker:")
                if (at < 0) emptyList() else listOf(InlinePicture(at, at + ":sticker:".length, "sticker"))
            },
            image = { _, _ -> },
        )
        setContent {
            InterceptPlatformTextInput(interceptor) {
                focusManager = LocalFocusManager.current
                CompositionLocalProvider(LocalEditorTextFieldOptimization provides true) {
                    EditorTextField(
                        state = state,
                        hint = "",
                        textStyle = TextStyle.Default,
                        inlinePictures = pictures,
                        modifier = Modifier.testTag("field"),
                    )
                }
            }
        }
        val field = onNodeWithTag("field")
        field.performTextInputSelection(TextRange(state.text.length))
        runOnIdle { assertEquals(1, starts, "The probe must start a real platform input session") }
        repeat(2) {
            field.performTextInput(":sticker:")
            field.assertIsFocused()
            runOnIdle {
                assertEquals("plain :sticker:", state.text.toString())
                assertEquals(1, starts, "Adding the first sticker must not restart the IME")
                assertEquals(0, cancellations)
            }
            field.performKeyInput { pressKey(Key.Backspace) }
            field.assertIsFocused()
            runOnIdle {
                assertEquals("plain ", state.text.toString())
                assertEquals(1, starts, "Removing the last sticker must not restart the IME")
                assertEquals(0, cancellations)
            }
        }
        field.performTextInput("tail")
        runOnIdle { assertEquals("plain tail", state.text.toString()) }
        // Positive control: the interceptor must also observe actual session cancellation.
        runOnIdle { focusManager.clearFocus(force = true) }
        runOnIdle {
            assertEquals(1, starts)
            assertEquals(1, cancellations)
        }
    }
}
