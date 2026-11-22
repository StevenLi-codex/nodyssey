package io.github.plaza.designsys.component

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertIsFocused
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextInputSelection
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.v2.runComposeUiTest
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import io.github.plaza.designsys.editor.InlinePicture
import io.github.plaza.designsys.editor.InlinePictures
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EditorTextFieldLayoutTest {
    /** Geometry is asserted only to catch a stale provider: stickers must follow current text. */
    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `typing before a sticker keeps its placeholder aligned and backspace atomic`() = runComposeUiTest {
        val state = TextFieldState("a :sticker: z")
        var stickerPosition: Offset? = null
        val pictures = InlinePictures(
            find = { source ->
                val at = source.indexOf(":sticker:")
                if (at < 0) emptyList() else listOf(InlinePicture(at, at + ":sticker:".length, "sticker"))
            },
            image = { _, modifier ->
                Box(modifier.onGloballyPositioned { stickerPosition = it.positionInRoot() })
            },
        )
        setContent {
            CompositionLocalProvider(LocalEditorTextFieldOptimization provides true) {
                EditorTextField(
                    state = state,
                    hint = "",
                    textStyle = TextStyle(fontSize = 18.sp),
                    inlinePictures = pictures,
                    modifier = Modifier.testTag("field"),
                )
            }
        }
        val field = onNodeWithTag("field")
        var before = Offset.Zero
        runOnIdle { before = requireNotNull(stickerPosition) }
        field.performTextInputSelection(TextRange(0))
        field.performTextInput("wide prefix ")
        val layouts = mutableListOf<TextLayoutResult>()
        field.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        runOnIdle {
            val result = layouts.single()
            val at = result.layoutInput.text.text.indexOf('\u53E3')
            assertTrue(at > 2, "The display must contain the transformed sticker, not raw Markdown")
            val placeholder = result.getBoundingBox(at)
            val position = requireNotNull(stickerPosition)
            assertTrue(position.x > before.x, "A retained getter must read the edited layout, not the initial result")
            assertTrue(
                position.x >= placeholder.left - 1f && position.x <= placeholder.right + 1f,
                "Sticker $position must follow the current placeholder $placeholder (rounded to physical pixels)",
            )
            assertEquals("wide prefix a :sticker: z", state.text.toString())
            assertEquals(TextRange("wide prefix ".length), state.selection)
        }
        field.performTextInputSelection(TextRange("wide prefix a :sticker:".length))
        field.performKeyInput { pressKey(Key.Backspace) }
        runOnIdle {
            assertEquals("wide prefix a  z", state.text.toString())
            assertEquals(TextRange("wide prefix a ".length), state.selection)
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `typing into plain text can add and remove a sticker without losing the editing session`() = runComposeUiTest {
        val state = TextFieldState("plain ")
        var renderedStickers = 0
        var stickerPosition: Offset? = null
        val pictures = InlinePictures(
            find = { source ->
                val at = source.indexOf(":sticker:")
                if (at < 0) emptyList() else listOf(InlinePicture(at, at + ":sticker:".length, "sticker"))
            },
            image = { _, modifier ->
                androidx.compose.runtime.SideEffect { renderedStickers++ }
                Box(modifier.onGloballyPositioned { stickerPosition = it.positionInRoot() })
            },
        )
        setContent {
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
        val field = onNodeWithTag("field")
        field.performTextInputSelection(TextRange(state.text.length))
        field.performTextInput(":sticker:")
        runOnIdle {
            assertTrue(renderedStickers > 0)
            assertEquals("plain :sticker:", state.text.toString())
            assertEquals(TextRange(state.text.length), state.selection)
        }
        field.assertIsFocused()
        field.performKeyInput { pressKey(Key.Backspace) }
        runOnIdle { assertEquals("plain ", state.text.toString()) }
        field.assertIsFocused()
        field.performTextInput("tail")
        runOnIdle {
            assertEquals("plain tail", state.text.toString())
            assertEquals(TextRange(state.text.length), state.selection)
        }
        // Re-enable after a plain-text interval. The retained getter must still read the same
        // live TextLayoutState and place the new sticker after the newly inserted text.
        field.performTextInput(":sticker:")
        val layouts = mutableListOf<TextLayoutResult>()
        field.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(layouts) }
        runOnIdle {
            val result = layouts.single()
            val at = result.layoutInput.text.text.indexOf('\u53E3')
            assertTrue(at >= 0)
            val placeholder = result.getBoundingBox(at)
            val position = requireNotNull(stickerPosition)
            assertTrue(
                position.x >= placeholder.left - 1f && position.x <= placeholder.right + 1f,
                "Re-enabled sticker $position must follow the current placeholder $placeholder",
            )
            assertEquals("plain tail:sticker:", state.text.toString())
        }
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `plain text remeasurement does not publish a new layout callback into snapshot state`() =
        assertRemeasurementCallbackWrites("ordinary text")

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `sticker remeasurement does not publish a fresh layout provider`() =
        assertRemeasurementCallbackWrites("before :sticker: after")

    @OptIn(ExperimentalTestApi::class)
    internal fun assertRemeasurementCallbackWrites(
        text: String,
        optimized: Boolean = true,
        expectedWrites: Int = 0,
    ) = runComposeUiTest {
        val width = mutableIntStateOf(300)
        val state = TextFieldState(text)
        var callbackWrites = 0
        var measurements = 0
        var measurementsBeforeResize = 0
        var observeWrites = false
        // This observes actual applied Compose state writes from the attached production field,
        // not a policy constant. Observe after settling so initialization is not counted. Reading
        // without observation is essential: otherwise the probe itself can subscribe the measure
        // phase to the state being written and manufacture a feedback loop.
        val observer = Snapshot.registerApplyObserver { changed, _ ->
            if (observeWrites) {
                callbackWrites += Snapshot.withoutReadObservation {
                    changed.count { it is State<*> && it.value is Function0<*> }
                }
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
            CompositionLocalProvider(LocalEditorTextFieldOptimization provides optimized) {
                EditorTextField(
                    state = state,
                    hint = "",
                    textStyle = TextStyle.Default,
                    inlinePictures = pictures,
                    modifier = Modifier.layout { measurable, constraints ->
                        measurements++
                        val child = measurable.measure(constraints.copy(maxWidth = width.intValue))
                        layout(child.width, child.height) { child.place(0, 0) }
                    },
                    container = { content ->
                        Box { content() }
                    },
                )
            }
        }
        runOnIdle {
            observeWrites = true
            measurementsBeforeResize = measurements
            width.intValue = 320
        }
        runOnIdle {
            observer.dispose()
            assertTrue(measurements > measurementsBeforeResize, "The probe must actually remeasure the field")
            assertEquals(
                expectedWrites,
                callbackWrites,
                "Remeasurement must not publish fresh layout provider lambdas on the optimized path",
            )
        }
    }
}
