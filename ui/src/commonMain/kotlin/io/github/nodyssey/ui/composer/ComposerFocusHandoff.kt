package io.github.nodyssey.ui.composer

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController

internal expect val iosComposerFocusHandoff: Boolean
internal expect fun checkComposerInputThread()

/** UI event handlers stay inline on Main: retain, clear, hide, then exactly one action. */
@Composable
internal fun composerInputAction(
    states: List<TextFieldState>,
    hideOnOtherPlatforms: Boolean = false,
    action: () -> Unit,
): () -> Unit {
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    return {
        runComposerInputAction(
            states = states,
            clearFocus = { focus.clearFocus() },
            hideKeyboard = { keyboard?.hide() },
            action = action,
            ios = iosComposerFocusHandoff,
            hideOnOtherPlatforms = hideOnOtherPlatforms,
        )
    }
}

internal fun runComposerInputAction(
    states: List<TextFieldState>,
    clearFocus: () -> Unit,
    hideKeyboard: () -> Unit,
    action: () -> Unit,
    ios: Boolean,
    hideOnOtherPlatforms: Boolean,
) {
    if (ios) {
        checkComposerInputThread()
        leaveIosComposerInput(states, clearFocus, hideKeyboard, action)
    } else {
        if (hideOnOtherPlatforms) hideKeyboard()
        action()
    }
}

/** Synchronous UI-callback handoff; callers must run on the main thread. */
internal fun leaveIosComposerInput(
    states: List<TextFieldState>,
    clearFocus: () -> Unit,
    hideKeyboard: () -> Unit,
    action: () -> Unit,
) {
    // Public edit retains the raw preedit string and selection while committing the marked
    // region. It does not choose an IME candidate; UIKit may finalize that later.
    states.forEach { state ->
        if (state.composition != null) {
            state.edit {
                val rawText = toString()
                val rawSelection = selection
                // An empty edit retains composition in Compose 1.13. Replacing with the
                // same text marks a programmatic edit, which commits it via public API.
                replace(0, length, rawText)
                selection = rawSelection
            }
        }
    }
    clearFocus()
    hideKeyboard()
    action()
}
