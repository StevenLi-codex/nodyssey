package io.github.nodyssey.ios.native

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.session.PrivatePostRepository
import io.github.nodyssey.data.session.PrivateStoreAccessDenied
import io.github.nodyssey.data.session.PrivateSessionBoundary
import io.github.nodyssey.data.session.PrivateStoreParticipant
import io.github.nodyssey.data.session.PrivateStorePhase
import io.github.nodyssey.data.session.PrivateStoreProvenance
import io.github.nodyssey.data.settings.AppLanguage
import io.github.nodyssey.data.settings.SettingsRepository
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.model.SearchHistoryEntry
import io.github.nodyssey.model.SearchTarget
import io.github.plaza.core.net.SessionCookieStore
import io.github.plaza.core.net.SessionCookies
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okio.Path.Companion.toPath
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Executes unchanged native settings dispatcher/observer and real file-backed shared stores. */
class NativePrivateSettingsJvmTest {
    private class Jar : SessionCookieStore {
        var account = "A"
        override fun cookieHeader(url: String) = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=$account"
        override fun setCookie(url: String, cookie: String): Unit = error("No live cookies")
        override suspend fun removeAll(): Unit = error("No cookie deletion")
        override fun flush() = Unit
    }

    private class Fixture {
        val directory = Files.createTempDirectory(java.nio.file.Path.of(System.getProperty("java.io.tmpdir")), "settings-").toFile()
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.Default)
        private fun store(name: String) = PreferenceDataStoreFactory.createWithPath(
            scope = scope,
            produceFile = { directory.resolve("$name.preferences_pb").path.toPath() },
        )
        var afterSettingsWrite: (suspend () -> Unit)? = null
        private val settingsStore = store("settings")
        val repository = SettingsRepository(object : androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences> {
            override val data = settingsStore.data
            override suspend fun updateData(
                transform: suspend (androidx.datastore.preferences.core.Preferences) -> androidx.datastore.preferences.core.Preferences,
            ): androidx.datastore.preferences.core.Preferences {
                val saved = settingsStore.updateData(transform)
                afterSettingsWrite?.also { afterSettingsWrite = null }?.invoke()
                return saved
            }
        })
        val jar = Jar()
        private val cookies = SessionCookies(NodeSeekSite.CONFIG, jar)
        val boundary = PrivateSessionBoundary(
            PrivateStoreProvenance(store("provenance"), setOf("history")),
            cookies::privateOwnerProof,
            listOf(PrivateStoreParticipant("history", {
                repository.settings.first().let { it.searchHistory.isEmpty() && it.recentBoards.isEmpty() }
            }, { error("These tests never authorize cleanup") })),
        )
        var trimCalls = 0
        val trimLimits = mutableListOf<Int>()
        // Only the broad raw PostRepository is a fixture. Admission is the exact production wrapper.
        private val rawPosts = java.lang.reflect.Proxy.newProxyInstance(
            PostRepository::class.java.classLoader,
            arrayOf(PostRepository::class.java),
        ) { _, method, _ ->
            check(method.name == "trimReadHistory") { "Unrelated repository call: ${method.name}" }
            trimCalls++
            trimLimits += runBlocking { repository.settings.first().readHistoryLimit }
            Unit
        } as PostRepository
        val context = NativeContext(
            IosAppContainer(mapOf(
                "settingsRepository" to repository,
                "privateBoundary" to boundary,
                "postRepository" to PrivatePostRepository(rawPosts, boundary),
            )),
            scope,
        )

        suspend fun reopenLimit(): Int {
            job.cancelAndJoin()
            val reopenedJob = SupervisorJob()
            try {
                val store = PreferenceDataStoreFactory.createWithPath(
                    scope = CoroutineScope(reopenedJob + Dispatchers.Default),
                    produceFile = { directory.resolve("settings.preferences_pb").path.toPath() },
                )
                return SettingsRepository(store).settings.first().readHistoryLimit
            } finally {
                reopenedJob.cancelAndJoin()
            }
        }

        suspend fun seed() {
            repository.setAppLanguage(AppLanguage.ENGLISH)
            repository.addSearchHistory(SearchHistoryEntry("private-query-A", SearchTarget.POSTS))
            repository.recordRecentBoard("private-board-A")
        }

        suspend fun initialize(ready: Boolean) {
            if (ready) boundary.reconcile()
            seed()
            if (!ready) boundary.reconcile()
            assertEquals(if (ready) PrivateStorePhase.READY else PrivateStorePhase.UNKNOWN, boundary.state.value.phase)
        }

        suspend fun switchOwner() {
            jar.account = "B"
            boundary.reconcile()
            assertEquals(PrivateStorePhase.UNKNOWN, boundary.state.value.phase)
        }

        suspend fun preserved() {
            val settings = repository.settings.first()
            assertEquals("private-query-A", settings.searchHistory.single().query)
            assertEquals(listOf("private-board-A"), settings.recentBoards)
            assertEquals(AppLanguage.ENGLISH, settings.appLanguage)
        }

        suspend fun close() {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    private suspend fun deniedLimit(readyFirst: Boolean) {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = readyFirst)
            if (readyFirst) fixture.switchOwner()
            val old = fixture.repository.settings.first().readHistoryLimit
            val requested = SettingsRepository.READ_HISTORY_LIMIT_CHOICES.first { it != old }
            kotlin.test.assertFailsWith<PrivateStoreAccessDenied> {
                fixture.context.settingsRequest("settings.set", settingsObject("key" to "readHistoryLimit", "value" to requested))
            }
            assertEquals(0, fixture.trimCalls)
            assertEquals(old, fixture.repository.settings.first().readHistoryLimit, "Denied trim must not leave a partially written preference")
            fixture.preserved()
            assertEquals(old, fixture.reopenLimit(), "Denied preference must remain unchanged on disk")
        } finally {
            fixture.close()
        }
    }

    @Test
    fun unknownLimitRefusalDoesNotPersistPreference() = runBlocking { deniedLimit(readyFirst = false) }

    @Test
    fun switchedOwnerLimitRefusalDoesNotPersistPreference() = runBlocking { deniedLimit(readyFirst = true) }

    @Test
    fun ownerChangeAfterPreferenceWriteCannotLeaveDeniedTrimPartiallyApplied() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = true)
            val old = fixture.repository.settings.first().readHistoryLimit
            val requested = SettingsRepository.READ_HISTORY_LIMIT_CHOICES.first { it != old }
            // Real DataStore has persisted the edit; nested production trim now refuses admission.
            fixture.afterSettingsWrite = { fixture.jar.account = "B" }
            kotlin.test.assertFailsWith<PrivateStoreAccessDenied> {
                fixture.context.settingsRequest("settings.set", settingsObject("key" to "readHistoryLimit", "value" to requested))
            }
            assertEquals(0, fixture.trimCalls)
            assertEquals(old, fixture.repository.settings.first().readHistoryLimit, "Mid-request denial must restore the global preference")
            fixture.preserved()
            assertEquals(old, fixture.reopenLimit())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun revocationAfterPersistJoinsPreferenceRollbackBeforeCompleting() = runBlocking {
        val fixture = Fixture()
        var writer: kotlinx.coroutines.Job? = null
        try {
            fixture.initialize(ready = true)
            val old = fixture.repository.settings.first().readHistoryLimit
            val requested = SettingsRepository.READ_HISTORY_LIMIT_CHOICES.first { it != old }
            val persisted = kotlinx.coroutines.CompletableDeferred<Unit>()
            fixture.afterSettingsWrite = {
                persisted.complete(Unit)
                kotlinx.coroutines.awaitCancellation()
            }
            writer = launch {
                fixture.context.settingsRequest("settings.set", settingsObject("key" to "readHistoryLimit", "value" to requested))
            }
            withTimeout(3000) { persisted.await() }
            withTimeout(3000) { fixture.switchOwner() }
            assertTrue(writer.isCompleted, "Revocation must join the settings writer")
            assertEquals(0, fixture.trimCalls)
            assertEquals(old, fixture.repository.settings.first().readHistoryLimit, "Cancellation after commit must not leave a partial preference")
            fixture.preserved()
            assertEquals(old, fixture.reopenLimit())
        } finally {
            writer?.cancelAndJoin()
            fixture.close()
        }
    }

    @Test
    fun admittedLimitStillTrimsUsingTheNewPersistedPreference() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = true)
            val old = fixture.repository.settings.first().readHistoryLimit
            val requested = SettingsRepository.READ_HISTORY_LIMIT_CHOICES.first { it != old }
            val value = fixture.context.settingsRequest("settings.set", settingsObject("key" to "readHistoryLimit", "value" to requested))!!
            assertPublic(value)
            assertEquals(requested, value.jsonObject.settingsInt("readHistoryLimit"))
            assertEquals(listOf(requested), fixture.trimLimits)
            fixture.preserved()
            assertEquals(requested, fixture.reopenLimit())
        } finally {
            fixture.close()
        }
    }

    @Test
    fun unknownPublicMutationRemainsUsableAndItsResponseIsRedacted() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = false)
            val value = fixture.context.settingsRequest("settings.set", settingsObject("key" to "oneHandMode", "value" to true))!!
            assertPublic(value)
            assertEquals(true, value.jsonObject.settingsBoolean("oneHandMode"))
            assertEquals(true, fixture.repository.settings.first().oneHandMode)
            fixture.preserved()
        } finally {
            fixture.close()
        }
    }

    private fun assertPublic(value: JsonElement) {
        val fields = value.jsonObject
        assertFalse("searchHistory" in fields, "Public settings must omit private searchHistory")
        assertFalse("recentBoards" in fields, "Public settings must omit private recentBoards")
        assertFalse(value.toString().contains("private-query-A"))
        assertFalse(value.toString().contains("private-board-A"))
        assertEquals("ENGLISH", fields.settingsString("appLanguage"))
        assertTrue("readHistoryLimit" in fields)
    }

    @Test
    fun unknownGetPreservesLegacyHistoryWithoutExportingIt() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = false)
            assertPublic(fixture.context.settingsRequest("settings.get", JsonObject(emptyMap()))!!)
            fixture.preserved()
        } finally {
            fixture.close()
        }
    }

    @Test
    fun unknownObserveKeepsPublicPreferencesAvailableWithoutHistory() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = false)
            assertPublic(withTimeout(3000) { fixture.context.settingsObserve("settings.observe", JsonObject(emptyMap()))!!.first() })
            fixture.preserved()
        } finally {
            fixture.close()
        }
    }

    @Test
    fun getNeverExportsHistoryEvenWhileAdmittedOrAfterOwnerSwitch() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.initialize(ready = true)
            val admitted = fixture.context.settingsRequest("settings.get", JsonObject(emptyMap()))!!
            fixture.switchOwner()
            val switched = fixture.context.settingsRequest("settings.get", JsonObject(emptyMap()))!!
            assertPublic(admitted)
            assertPublic(switched)
            fixture.preserved()
        } finally {
            fixture.close()
        }
    }

    @Test
    fun continuingPublicObserverNeverReplaysOldOwnerHistory() = runBlocking {
        val fixture = Fixture()
        val received = Channel<JsonElement>(Channel.UNLIMITED)
        var observer: kotlinx.coroutines.Job? = null
        try {
            fixture.initialize(ready = true)
            observer = launch {
                fixture.context.settingsObserve("settings.observe", JsonObject(emptyMap()))!!.collect { received.send(it) }
            }
            val admitted = withTimeout(3000) { received.receive() }
            fixture.switchOwner()
            // Force another settings emission without deleting the previous owner's rows.
            fixture.repository.setOneHandMode(true)
            val switched = withTimeout(3000) {
                var next = received.receive()
                while (!next.jsonObject.settingsBoolean("oneHandMode")) next = received.receive()
                next
            }
            assertPublic(admitted)
            assertPublic(switched)
            fixture.preserved()
        } finally {
            observer?.cancelAndJoin()
            fixture.close()
            received.close()
        }
    }
}
