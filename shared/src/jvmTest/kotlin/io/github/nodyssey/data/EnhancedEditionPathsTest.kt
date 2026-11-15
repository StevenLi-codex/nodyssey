package io.github.nodyssey.data

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.data.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import okio.Path.Companion.toPath
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class EnhancedEditionPathsTest {
    @Test
    fun `fresh edition phrases reopen without adopting or touching legacy sandbox files`() = runBlocking {
        val temporaryRoot = java.nio.file.Path.of(System.getenv("TMPDIR") ?: System.getProperty("java.io.tmpdir"))
        val sandbox = Files.createTempDirectory(temporaryRoot, "edition-overlay")
        val support = Files.createDirectories(sandbox.resolve("Library/Application Support"))
        val caches = Files.createDirectories(sandbox.resolve("Library/Caches"))
        val legacyFiles = listOf(
            support.resolve("nodeseek.db"),
            support.resolve("settings.preferences_pb"),
            support.resolve("post-composer.preferences_pb"),
            support.resolve("io.github.nodyssey.no-backup/proxy.preferences_pb"),
            support.resolve("io.github.nodyssey.single-local-v1/NodeSeek/private.db"),
            support.resolve("offline/images/old-image"),
            caches.resolve("image_cache/old-image"),
        )
        val before = legacyFiles.associateWith { file ->
            Files.createDirectories(file.parent)
            val bytes = "unknown existing private bytes ${file.fileName}".toByteArray()
            Files.write(file, bytes)
            bytes.toList()
        }
        var job = SupervisorJob()
        try {
            val paths = EnhancedEditionPaths(support.toString(), caches.toString())
            val activeRoot = Files.createDirectories(java.nio.file.Path.of(paths.supportRoot))
            val path = activeRoot.resolve("settings.preferences_pb").toString().toPath()
            fun open() = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.IO)) { path }
            var repository = SettingsRepository(open())
            assertTrue(repository.savedPhrases.phrases.first().isEmpty())
            repository.savedPhrases.save("Manual", "Retained in enhanced edition only")
            job.cancelAndJoin()
            job = SupervisorJob()
            // A process restart or account change cannot choose an alternate root: no identity input.
            val reopened = EnhancedEditionPaths(support.toString(), caches.toString())
            assertEquals(paths.supportRoot, reopened.supportRoot)
            assertEquals(paths.cacheRoot, reopened.cacheRoot)
            repository = SettingsRepository(open())
            assertEquals("Retained in enhanced edition only", repository.savedPhrases.phrases.first().single().body)
            assertFalse(activeRoot.startsWith(caches))
            assertFalse(java.nio.file.Path.of(paths.cacheRoot).startsWith(caches.resolve("image_cache")))
            before.forEach { (file, bytes) -> assertEquals(bytes, Files.readAllBytes(file).toList(), file.toString()) }
        } finally {
            job.cancelAndJoin()
            sandbox.toFile().deleteRecursively()
        }
    }
}
