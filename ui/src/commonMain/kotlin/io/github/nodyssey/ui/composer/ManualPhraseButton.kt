package io.github.nodyssey.ui.composer

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.data.settings.SavedPhrase
import io.github.nodyssey.data.settings.SavedPhraseStore
import io.github.nodyssey.ui.resources.Res
import io.github.nodyssey.ui.resources.action_cancel
import io.github.nodyssey.ui.resources.action_close
import io.github.nodyssey.ui.resources.action_delete
import io.github.nodyssey.ui.resources.action_save
import io.github.nodyssey.ui.resources.manual_extra_failed
import io.github.nodyssey.ui.resources.manual_phrase_body
import io.github.nodyssey.ui.resources.manual_phrase_edit
import io.github.nodyssey.ui.resources.manual_phrase_name
import io.github.nodyssey.ui.resources.manual_phrases
import io.github.nodyssey.ui.resources.manual_phrases_help
import io.github.plaza.core.runCatchingExceptCancellation
import io.github.plaza.designsys.editor.MarkdownEditorState
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch
import org.jetbrains.compose.resources.stringResource

val LocalSavedPhrases = staticCompositionLocalOf<SavedPhraseStore?> { null }
val LocalExtraSession = staticCompositionLocalOf<StateFlow<SessionState>?> { null }

/** One extra toolbar entry; absent unless the platform explicitly supplies the capability. */
@Composable
internal fun ManualPhraseButton(
    body: TextFieldState,
    editor: MarkdownEditorState,
    title: TextFieldState? = null,
    enabled: Boolean = true,
) {
    val store = LocalSavedPhrases.current ?: return
    val sessions = LocalExtraSession.current ?: return
    val session by sessions.collectAsStateWithLifecycle()
    var openedFor by remember { mutableStateOf<SessionState?>(null) }
    val focus = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    TextButton(enabled = enabled, onClick = {
        prepareManualPhrasePicker(editor, listOfNotNull(title, body)) {
            focus.clearFocus(force = true)
            keyboard?.hide()
            openedFor = sessions.value
        }
    }) { Text(stringResource(Res.string.manual_phrases)) }
    LaunchedEffect(session) { if (openedFor != session) openedFor = null }
    if (openedFor == session) {
        ManualPhraseDialog(store, onDismiss = { openedFor = null }, onInsert = { text ->
            if (enabled && openedFor == sessions.value) insertManualPhrase(body, text)
            openedFor = null
        })
    }
}

@Composable
private fun ManualPhraseDialog(store: SavedPhraseStore, onDismiss: () -> Unit, onInsert: (String) -> Unit) {
    var failed by remember { mutableStateOf(false) }
    val flow = remember(store) { store.phrases.catch { failed = true } }
    val phrases by flow.collectAsStateWithLifecycle(initialValue = emptyList())
    var editing by remember { mutableStateOf<SavedPhrase?>(null) }
    var name by remember { mutableStateOf("") }
    var body by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    fun write(action: suspend () -> Unit) {
        busy = true
        scope.launch {
            try {
                failed = runCatchingExceptCancellation { action() }.isFailure
            } finally {
                busy = false
            }
        }
    }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(stringResource(Res.string.manual_phrases)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(stringResource(Res.string.manual_phrases_help))
                if (failed) Text(stringResource(Res.string.manual_extra_failed))
                phrases.forEach { phrase ->
                    Row {
                        TextButton(enabled = !busy, onClick = { onInsert(phrase.body) }) { Text(phrase.name) }
                        TextButton(enabled = !busy, onClick = {
                            editing = phrase
                            name = phrase.name
                            body = phrase.body
                        }) { Text(stringResource(Res.string.manual_phrase_edit)) }
                        TextButton(enabled = !busy, onClick = { write { store.remove(phrase.name) } }) {
                            Text(stringResource(Res.string.action_delete))
                        }
                    }
                }
                OutlinedTextField(
                    value = name,
                    enabled = !busy && editing == null,
                    onValueChange = { name = it.take(60) },
                    label = { Text(stringResource(Res.string.manual_phrase_name)) },
                )
                OutlinedTextField(
                    value = body,
                    enabled = !busy,
                    onValueChange = { body = it.take(4000) },
                    label = { Text(stringResource(Res.string.manual_phrase_body)) },
                )
                TextButton(enabled = !busy && name.isNotBlank() && body.isNotBlank(), onClick = {
                    write {
                        store.save(name, body)
                        editing = null
                        name = ""
                        body = ""
                    }
                }) { Text(stringResource(Res.string.action_save)) }
                if (editing != null) {
                    TextButton(onClick = {
                        editing = null
                        name = ""
                        body = ""
                    }) {
                        Text(stringResource(Res.string.action_cancel))
                    }
                }
            }
        },
        confirmButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(stringResource(Res.string.action_close)) } },
    )
}
