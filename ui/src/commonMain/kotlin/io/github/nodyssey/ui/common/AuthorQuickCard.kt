package io.github.nodyssey.ui.common

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.github.nodyssey.data.ProfileRepository
import io.github.nodyssey.data.UserProfile
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.ui.composer.LocalExtraSession
import io.github.nodyssey.ui.resources.Res
import io.github.nodyssey.ui.resources.action_close
import io.github.nodyssey.ui.resources.loading_indicator_label
import io.github.nodyssey.ui.resources.manual_author_card
import io.github.nodyssey.ui.resources.manual_author_facts
import io.github.nodyssey.ui.resources.manual_author_full
import io.github.nodyssey.ui.resources.manual_extra_failed
import io.github.nodyssey.ui.resources.manual_unknown
import io.github.plaza.core.runCatchingExceptCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.jetbrains.compose.resources.stringResource

val LocalQuickProfiles = staticCompositionLocalOf<ProfileRepository?> { null }

internal suspend fun loadAuthorQuickCard(
    uid: Long,
    openedFor: SessionState,
    profiles: ProfileRepository,
    currentSession: () -> SessionState,
): UserProfile? {
    require(uid > 0)
    if (currentSession() != openedFor) return null
    val result = profiles.profile(uid)
    currentCoroutineContext().ensureActive()
    if (currentSession() != openedFor) return null
    check(result.uid == uid) { "Profile identity mismatch" }
    return result
}

private data class AuthorRequest(val uid: Long, val session: SessionState)

/** Explicit author taps only. Full-profile navigation is still the original callback. */
@Composable
fun rememberAuthorQuickCard(onFullProfile: (Long) -> Unit): (Long) -> Unit {
    val profiles = LocalQuickProfiles.current ?: return onFullProfile
    val sessions = LocalExtraSession.current ?: return onFullProfile
    val session by sessions.collectAsStateWithLifecycle()
    var request by remember { mutableStateOf<AuthorRequest?>(null) }
    val opened = request
    var profile by remember(opened) { mutableStateOf<UserProfile?>(null) }
    var failed by remember(opened) { mutableStateOf(false) }
    LaunchedEffect(opened) {
        if (opened != null) {
            runCatchingExceptCancellation {
                loadAuthorQuickCard(opened.uid, opened.session, profiles) { sessions.value }
            }.onSuccess { profile = it }.onFailure { failed = true }
        }
    }
    LaunchedEffect(session) { if (opened?.session != session) request = null }
    // Fence synchronously before drawing, not only in the later lifecycle effect.
    if (opened != null && opened.session == session && opened.session == sessions.value) {
        val shown = profile?.takeIf { it.uid == opened.uid }
        val unknown = stringResource(Res.string.manual_unknown)
        AlertDialog(
            onDismissRequest = { request = null },
            title = { Text(shown?.name ?: stringResource(Res.string.manual_author_card)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    when {
                        failed -> Text(stringResource(Res.string.manual_extra_failed))

                        shown == null -> Text(stringResource(Res.string.loading_indicator_label))

                        else -> {
                            Text(
                                stringResource(
                                    Res.string.manual_author_facts,
                                    shown.uid,
                                    shown.rank?.toString() ?: unknown,
                                    shown.createdAt ?: unknown,
                                    shown.topicCount?.toString() ?: unknown,
                                    shown.commentCount?.toString() ?: unknown,
                                ),
                            )
                            shown.bio?.let { Text(it) }
                            // Existing device-local note contract. No new fetch or absence claim.
                            LocalUserNotes.current.noteFor(shown.uid)?.let { Text(it) }
                        }
                    }
                }
            },
            confirmButton = {
                TextButton(enabled = shown != null, onClick = {
                    if (opened.session == sessions.value && shown?.uid == opened.uid) {
                        request = null
                        onFullProfile(opened.uid)
                    }
                }) { Text(stringResource(Res.string.manual_author_full)) }
            },
            dismissButton = {
                TextButton(onClick = { request = null }) { Text(stringResource(Res.string.action_close)) }
            },
        )
    }
    return { uid -> if (uid > 0) request = AuthorRequest(uid, sessions.value) }
}
