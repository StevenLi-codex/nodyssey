package io.github.nodyssey.data.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
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
import kotlin.test.assertFailsWith

class SavedPhraseStoreTest {
    @Test
    fun `named phrases replace atomically and survive reopening without touching other settings`() = runBlocking {
        val temporaryRoot = java.nio.file.Path.of(System.getenv("TMPDIR") ?: System.getProperty("java.io.tmpdir"))
        val directory = Files.createTempDirectory(temporaryRoot, "phrases")
        val path = directory.resolve("settings.preferences_pb").toString().toPath()
        var job = SupervisorJob()
        fun open() = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.IO)) { path }
        var repository = SettingsRepository(open())
        repository.setFontScale(1.2f)
        assertEquals(emptyList(), repository.savedPhrases.phrases.first())
        repository.savedPhrases.save("Greeting", "Hello\nworld")
        repository.savedPhrases.save("Greeting", "  Replacement\n正文  ")
        assertEquals(listOf(SavedPhrase("Greeting", "  Replacement\n正文  ")), repository.savedPhrases.phrases.first())
        assertFailsWith<IllegalArgumentException> { repository.savedPhrases.save(" ", "body") }
        assertFailsWith<IllegalArgumentException> { repository.savedPhrases.save("Blank", "  ") }
        job.cancelAndJoin()
        job = SupervisorJob()
        repository = SettingsRepository(open())
        assertEquals("  Replacement\n正文  ", repository.savedPhrases.phrases.first().single().body)
        assertEquals(1.2f, repository.settings.first().fontScale)
        repository.savedPhrases.remove("Greeting")
        assertEquals(emptyList(), repository.savedPhrases.phrases.first())
        job.cancelAndJoin()
        directory.toFile().deleteRecursively()
        Unit
    }
}
