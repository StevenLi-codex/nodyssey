package io.github.nodyssey.data.session

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Kotlin-only equality proof. Neither its value nor its hash is a native UI identity. */
class PrivateOwnerProof internal constructor(internal val encoded: String) {
    override fun equals(other: Any?): Boolean = other is PrivateOwnerProof && encoded == other.encoded
    override fun hashCode(): Int = encoded.hashCode()
    override fun toString(): String = "PrivateOwnerProof(REDACTED)"
}

enum class PrivateStorePhase { UNKNOWN, TRANSITIONING, READY }

/** A journal, not a transaction across Room and DataStore. Interrupted cleanup remains closed. */
class PrivateStoreProvenance(
    private val store: DataStore<Preferences>,
    internal val inventory: Set<String>,
) {
    @Serializable
    internal data class Manifest(
        val version: Int = 1,
        val phase: PrivateStorePhase = PrivateStorePhase.UNKNOWN,
        val owner: String? = null,
        val token: String? = null,
        val stores: Set<String> = emptySet(),
        val completed: Set<String> = emptySet(),
    )

    private val key = stringPreferencesKey("private-store-manifest-v1")
    private val json = Json { ignoreUnknownKeys = false }

    internal suspend fun load(): Manifest {
        val encoded = store.data.first()[key] ?: return Manifest(version = 0)
        return runCatching { json.decodeFromString<Manifest>(encoded) }.getOrNull()
            ?.takeIf { it.version == 1 && it.stores == inventory }
            ?: Manifest()
    }

    internal suspend fun begin(owner: PrivateOwnerProof, token: String) {
        write(Manifest(phase = PrivateStorePhase.TRANSITIONING, owner = owner.encoded, token = token, stores = inventory))
    }

    internal suspend fun unknown() {
        write(Manifest(stores = inventory))
    }

    internal suspend fun completed(token: String, id: String) {
        require(id in inventory)
        update(token) { it.copy(completed = it.completed + id) }
    }

    internal suspend fun commit(token: String) {
        update(token) {
            check(it.completed == inventory) { "Incomplete private-store cleanup" }
            it.copy(phase = PrivateStorePhase.READY, token = null)
        }
    }

    private suspend fun update(token: String, transform: (Manifest) -> Manifest) {
        store.edit { preferences ->
            val current = preferences[key]?.let { json.decodeFromString<Manifest>(it) }
            check(current != null && current.version == 1 && current.stores == inventory &&
                current.phase == PrivateStorePhase.TRANSITIONING && current.token == token)
            preferences[key] = json.encodeToString(transform(current))
        }
    }

    private suspend fun write(manifest: Manifest) {
        store.edit { it[key] = json.encodeToString(manifest) }
    }
}
