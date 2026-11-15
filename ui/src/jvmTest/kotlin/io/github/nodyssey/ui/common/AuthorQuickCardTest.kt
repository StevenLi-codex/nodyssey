package io.github.nodyssey.ui.common

import io.github.nodyssey.data.ProfileRepository
import io.github.nodyssey.data.UserProfile
import io.github.nodyssey.data.session.SessionState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class AuthorQuickCardTest {
    @Test
    fun `late profile after account generation changes is discarded`() = runTest {
        val gate = CompletableDeferred<Unit>()
        var session = SessionState(generation = 1)
        val repository = profiles {
            gate.await()
            UserProfile(42, "Author", "")
        }
        val loading = async { loadAuthorQuickCard(42, session, repository) { session } }
        testScheduler.runCurrent()
        session = session.copy(generation = 2)
        gate.complete(Unit)
        assertNull(loading.await())
    }

    @Test
    fun `wrong UID never becomes visible and missing fields remain missing`() = runTest {
        val session = SessionState()
        assertFailsWith<IllegalStateException> {
            loadAuthorQuickCard(42, session, profiles { UserProfile(7, "Wrong", "") }) { session }
        }
        val profile = loadAuthorQuickCard(42, session, profiles { UserProfile(42, "Author", "") }) { session }
        assertEquals(42L, profile?.uid)
        assertNull(profile?.topicCount)
        assertNull(profile?.rank)
    }

    private fun profiles(load: suspend () -> UserProfile) = object : ProfileRepository {
        override suspend fun profile(refresh: Boolean): UserProfile = error("Self lookup forbidden")
        override suspend fun profile(uid: Long): UserProfile = load()
    }
}
