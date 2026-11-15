package io.github.nodyssey.ios

import androidx.datastore.preferences.core.*
import io.github.nodyssey.data.composer.PostDraft
import io.github.nodyssey.data.local.importGlobalCatalogues
import io.github.nodyssey.data.session.*
import io.github.nodyssey.data.settings.SettingsRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import java.io.File
import java.nio.file.Files
import org.junit.Test
import kotlin.test.*

class OwnedWorkspaceGraphTest {
    @Test fun productionGraphRoutesAllPrivateStoresAndReopensExactProof() = runBlocking {
        val root = Files.createTempDirectory("owned-workspace-").toFile()
        fixtureRoot = root
        val jar = CookieFixture()
        var globals = IosGlobalServices(root, jar)
        var graphs = mutableListOf<IosAppContainer>()
        suspend fun router(): PrivateWorkspaceRouter<IosAppContainer> = PrivateWorkspaceRouter(
            io.github.nodyssey.data.createPreferenceDataStore("routing", globals.scope, root.path),
            globals.sessionRepository::privateOwnerProof, { globals.sessionRepository.peek().isSignedIn },
            build = { id -> IosAppContainer(globals, id, id?.let { File(root,it).apply { mkdirs() }.path }).also { it.lifetime.start(); graphs += it } },
            boundary = { it.privateBoundary }, close = { it.close() }, bind = { it.prepare() },
        )
        try {
            val settings = SettingsRepository(globals.settingsDataStore)
            settings.recordRecentBoard("legacy")
            globals.settingsDataStore.edit { it[stringPreferencesKey("report_compare_basket")] = "corrupt-private-report" }
            val before = globals.settingsDataStore.data.first()
            var routing = router()
            val legacy = routing.start()
            assertEquals(PrivateStorePhase.UNKNOWN, legacy.privateBoundary.state.value.phase)
            val first = routing.create(true, legacy.privateBoundary.state.value.identityEpoch)
            assertEquals(PrivateStorePhase.READY, first.privateBoundary.state.value.phase)
            assertNull(first.postComposerRepository.draft.first())
            assertTrue(first.settingsRepository.settings.first().recentBoards.isEmpty())
            first.postComposerRepository.saveDraft(PostDraft(title="A-private"))
            first.privateBoundary.protect { first.settingsRepository.recordRecentBoard("a-board"); first.offlineLibrary.download(listOf(77)) }
            first.offlineFiles.write("private-image",byteArrayOf(7,8))
            assertEquals(before, globals.settingsDataStore.data.first())
            val id = first.workspaceId
            first.privateBoundary.quarantine(); first.close(); globals.close()
            graphs = mutableListOf()
            globals = IosGlobalServices(root,jar)
            routing = router()
            val reopened = routing.start()
            assertEquals(id,reopened.workspaceId)
            assertEquals("A-private", reopened.postComposerRepository.draft.first()?.title)
            assertEquals(listOf("a-board"), reopened.settingsRepository.settings.first().recentBoards)
            assertFalse(reopened.offlineFiles.isEmpty())
            jar.header = "${io.github.nodyssey.core.NodeSeekSite.CONFIG.sessionCookieNames.first()}=b"
            reopened.privateBoundary.reconcile()
            assertFailsWith<PrivateStoreAccessDenied> { reopened.postComposerRepository.draft.first() }
            val next = routing.create(true,reopened.privateBoundary.state.value.identityEpoch)
            assertNotEquals(id,next.workspaceId)
            assertNull(next.postComposerRepository.draft.first())
            assertTrue(next.settingsRepository.settings.first().recentBoards.isEmpty())
            assertTrue(next.offlineFiles.isEmpty())
            val preservedCache=File(root,"$id/cache/image_cache/old-byte").apply { parentFile.mkdirs(); writeText("preserve") }
            val activeCache=File(root,"${next.workspaceId}/cache/temporary").apply { parentFile.mkdirs(); writeText("clear") }
            next.appCacheStore.clear()
            assertFalse(activeCache.exists())
            assertEquals("preserve",preservedCache.readText())
            assertTrue(File(root,"$id/offline/images/private-image").readBytes().contentEquals(byteArrayOf(7,8)))
            assertEquals(before,globals.settingsDataStore.data.first())
        } finally {
            graphs.forEach { runCatching { it.privateBoundary.quarantine(); it.close() } }
            globals.close(); root.deleteRecursively()
        }
    }

    @Test fun globalCatalogueImportNeverCopiesPrivateRowsOrRewritesLegacy() = runBlocking {
        val root=Files.createTempDirectory("catalogue-import-").toFile()
        val source=io.github.nodyssey.data.local.createNodeSeekDatabase(File(root,"legacy.db").path)
        val target=io.github.nodyssey.data.local.createNodeSeekDatabase(File(root,"global.db").path)
        try {
            source.titleKeywordDao().insert(io.github.nodyssey.data.local.TitleKeywordEntity(io.github.nodyssey.model.TitleKeywordKind.BLOCK,"global-rule",1))
            source.userNoteDao().upsert(io.github.nodyssey.data.local.UserNoteEntity(7,"private-note",1))
            source.close()
            val before=File(root,"legacy.db").readBytes()
            target.importGlobalCatalogues { androidx.sqlite.driver.bundled.BundledSQLiteDriver().open(File(root,"legacy.db").path,1) }
            assertEquals(listOf("global-rule"),target.titleKeywordDao().list(io.github.nodyssey.model.TitleKeywordKind.BLOCK).map { it.keyword })
            assertTrue(target.userNoteDao().observeAll().first().isEmpty())
            assertContentEquals(before,File(root,"legacy.db").readBytes())
            target.titleKeywordDao().delete(io.github.nodyssey.model.TitleKeywordKind.BLOCK,"global-rule")
            target.importGlobalCatalogues { error("Completed import must not reopen legacy") }
            assertTrue(target.titleKeywordDao().list(io.github.nodyssey.model.TitleKeywordKind.BLOCK).isEmpty())
        } finally { source.close(); target.close(); root.deleteRecursively() }
    }

}
