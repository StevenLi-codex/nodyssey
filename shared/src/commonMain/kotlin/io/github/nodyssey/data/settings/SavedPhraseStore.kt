package io.github.nodyssey.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class SavedPhrase(val name: String, val body: String)

/** Device-local templates, not account drafts. Shares SettingsRepository's existing DataStore. */
class SavedPhraseStore internal constructor(private val dataStore: DataStore<Preferences>) {
    private val key = stringPreferencesKey("manual_saved_phrases_v1")
    private val json = Json { ignoreUnknownKeys = true }
    val phrases = dataStore.data.map { decode(it[key]) }

    /** Same name edits in place; the body is preserved byte-for-byte, including Markdown whitespace. */
    suspend fun save(name: String, body: String) {
        val label = name.trim()
        require(label.isNotEmpty() && label.length <= 60)
        require(body.isNotBlank() && body.length <= 4000)
        dataStore.edit { preferences ->
            val entries = decode(preferences[key]).toMutableList()
            val index = entries.indexOfFirst { it.name == label }
            val phrase = SavedPhrase(label, body)
            if (index >= 0) {
                entries[index] = phrase
            } else {
                require(entries.size < 50)
                entries.add(phrase)
            }
            preferences[key] = json.encodeToString(entries)
        }
    }

    suspend fun remove(name: String) {
        dataStore.edit { preferences ->
            preferences[key] = json.encodeToString(decode(preferences[key]).filterNot { it.name == name })
        }
    }

    // Do not turn a corrupt collection into an empty success and overwrite the original bytes.
    private fun decode(raw: String?): List<SavedPhrase> = raw?.let { json.decodeFromString(it) } ?: emptyList()
}
