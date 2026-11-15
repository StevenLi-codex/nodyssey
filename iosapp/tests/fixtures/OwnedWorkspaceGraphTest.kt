package io.github.nodyssey.ios

import androidx.datastore.preferences.core.*
import io.github.nodyssey.data.composer.PostDraft
import io.github.nodyssey.data.session.*
import io.github.nodyssey.data.settings.SettingsRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import java.io.File
import java.nio.file.Files
import org.junit.Test
import kotlin.test.*

/** Real production graph, real Room/DataStore; Apple services/Coil are platform fixtures. */
class OwnedWorkspaceGraphTest {
    @Test fun cancelledLoginDuringOldWriterDrainReopensLocalProfile() = runBlocking {
        val root = Files.createTempDirectory("single-cancel-").toFile()
        fixtureRoot = root
        val globals = IosGlobalServices(root, CookieFixture())
        val graph = IosAppContainer(globals, File(root,"single-local-v1").apply { mkdirs() }.path)
        val entered = CompletableDeferred<Unit>()
        val draining = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        try {
            graph.lifetime.start(); graph.privateBoundary.reconcile()
            val writer = launch {
                graph.privateBoundary.protect {
                    entered.complete(Unit)
                    try { awaitCancellation() } finally {
                        withContext(NonCancellable) { draining.complete(Unit); release.await() }
                    }
                }
            }
            withTimeout(2000) { entered.await() }
            val login = launch { graph.privateBoundary.sessionMutation { error("Cancelled before auth dispatch") } }
            withTimeout(2000) { draining.await() }
            login.cancel(); release.complete(Unit)
            withTimeout(2000) { login.join(); writer.join() }
            assertEquals(PrivateStorePhase.READY, graph.privateBoundary.state.value.phase)
            graph.postComposerRepository.saveDraft(PostDraft(title="cancel preserved usability"))
        } finally { release.complete(Unit); graph.close(); globals.close(); root.deleteRecursively() }
    }

    @Test fun joinedOldWriterCannotPublishIntoNewEpochAndAuthErrorDoesNotLock() = runBlocking {
        val root = Files.createTempDirectory("single-lifetime-").toFile()
        fixtureRoot = root
        val jar = CookieFixture()
        val globals = IosGlobalServices(root, jar)
        val graph = IosAppContainer(globals, File(root,"single-local-v1").apply { mkdirs() }.path)
        val entered = CompletableDeferred<Unit>()
        val cleaning = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var stalePublished = false
        try {
            graph.lifetime.start(); graph.privateBoundary.reconcile()
            val old = graph.privateBoundary.state.value.identityEpoch
            val writer = launch {
                graph.privateBoundary.protect {
                    entered.complete(Unit)
                    try { awaitCancellation() } finally {
                        withContext(NonCancellable) { cleaning.complete(Unit); release.await() }
                    }
                }
                stalePublished = true
            }
            withTimeout(2000) { entered.await() }
            val auth = async {
                assertFailsWith<IllegalArgumentException> {
                    graph.privateBoundary.sessionMutation {
                        jar.header = "${io.github.nodyssey.core.NodeSeekSite.CONFIG.sessionCookieNames.first()}=new"
                        throw IllegalArgumentException("fixture parser failure after cookie")
                    }
                }
            }
            withTimeout(2000) { cleaning.await() }
            assertFalse(auth.isCompleted)
            assertEquals(PrivateStorePhase.TRANSITIONING, graph.privateBoundary.state.value.phase)
            release.complete(Unit)
            withTimeout(2000) { writer.join(); auth.await() }
            assertFalse(stalePublished)
            assertNotEquals(old, graph.privateBoundary.state.value.identityEpoch)
            assertEquals(PrivateStorePhase.READY, graph.privateBoundary.state.value.phase)
            graph.postComposerRepository.saveDraft(PostDraft(title="after failed auth"))
            assertEquals("after failed auth",graph.postComposerRepository.draft.first()?.title)
            assertFailsWith<PrivateStoreAccessDenied> { graph.privateBoundary.reset(true, graph.privateBoundary.state.value.identityEpoch) }
            Unit
        } finally { release.complete(Unit); graph.close(); globals.close(); root.deleteRecursively() }
    }

    @Test fun singleLocalProfileSurvivesGuestLoginLogoutAndRestartWithoutAdoptingLegacy() = runBlocking {
        val root = Files.createTempDirectory("single-profile-").toFile()
        fixtureRoot = root
        val jar = CookieFixture().apply { header = "" }
        var globals = IosGlobalServices(root, jar)
        val profile = File(root, "single-local-v1").apply { mkdirs() }
        var graph = IosAppContainer(globals, profile.path)
        try {
            globals.settingsDataStore.edit {
                it[stringPreferencesKey("recent_boards")] = "[\"legacy\"]"
                it[stringPreferencesKey("report_compare_basket")] = "corrupt-private-report"
                it[stringPreferencesKey("unknown_future_private_key")] = "must-not-import"
                it[stringPreferencesKey("theme_mode")] = "DARK"
            }
            val legacyBytes = globals.settingsDataStore.data.first()
            val preserved = listOf("legacy.db", "post-composer.preferences_pb", "comment-composer.preferences_pb", "offline/images/old", "cache/image_cache/old", "private-store-provenance.preferences_pb").map {
                File(root,it).apply { parentFile.mkdirs(); writeText("UNKNOWN legacy bytes $it") }
            }
            val snapshots = preserved.associateWith { it.readBytes() }
            graph.lifetime.start()
            graph.privateBoundary.reconcile()
            assertEquals(PrivateStorePhase.READY, graph.privateBoundary.state.value.phase)
            assertTrue(graph.settingsRepository.settings.first().recentBoards.isEmpty())
            assertNull(graph.postComposerRepository.draft.first())
            graph.postComposerRepository.saveDraft(PostDraft(title="device-local draft"))
            graph.privateBoundary.protect { graph.settingsRepository.recordRecentBoard("guest-read") }
            val guestEpoch = graph.privateBoundary.state.value.identityEpoch
            graph.privateBoundary.sessionMutation { jar.header = "${io.github.nodyssey.core.NodeSeekSite.CONFIG.sessionCookieNames.first()}=a" }
            assertEquals(PrivateStorePhase.READY, graph.privateBoundary.state.value.phase)
            assertNotEquals(guestEpoch, graph.privateBoundary.state.value.identityEpoch)
            assertTrue(graph.sessionRepository.state.value.isSignedIn)
            assertEquals("device-local draft", graph.postComposerRepository.draft.first()?.title)
            graph.privateBoundary.sessionMutation { jar.removeAll() }
            assertFalse(graph.sessionRepository.state.value.isSignedIn)
            assertEquals(PrivateStorePhase.READY, graph.privateBoundary.state.value.phase)
            graph.privateBoundary.sessionMutation { jar.header = "${io.github.nodyssey.core.NodeSeekSite.CONFIG.sessionCookieNames.first()}=b" }
            graph.offlineFiles.write("new-image", byteArrayOf(7,8))
            graph.appCacheStore.clear()
            snapshots.forEach { (file, bytes) -> assertContentEquals(bytes, file.readBytes()) }
            assertEquals(legacyBytes, globals.settingsDataStore.data.first())
            graph.close(); globals.close()
            globals = IosGlobalServices(root, jar)
            graph = IosAppContainer(globals, profile.path)
            graph.lifetime.start(); graph.privateBoundary.reconcile()
            assertEquals("device-local draft", graph.postComposerRepository.draft.first()?.title)
            assertEquals(listOf("guest-read"), graph.settingsRepository.settings.first().recentBoards)
            assertFalse(graph.offlineFiles.isEmpty())
            snapshots.forEach { (file, bytes) -> assertContentEquals(bytes, file.readBytes()) }
        } finally { graph.close(); globals.close(); root.deleteRecursively() }
    }
}
