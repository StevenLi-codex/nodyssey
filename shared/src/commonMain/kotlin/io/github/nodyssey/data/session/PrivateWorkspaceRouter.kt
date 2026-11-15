package io.github.nodyssey.data.session

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlin.uuid.Uuid

/** Process-owned router. Graphs are immutable snapshots; a lease never follows this pointer.
 * Only a committed pointer may reopen. Preparing candidates are retained, never adopted/deleted.
 */
class PrivateWorkspaceRouter<G : Any>(
    private val journal: DataStore<Preferences>,
    private val owner: () -> PrivateOwnerProof,
    private val signedIn: () -> Boolean,
    private val build: suspend (String?) -> G,
    private val boundary: (G) -> PrivateSessionBoundary,
    private val close: suspend (G) -> Unit,
    private val bind: suspend (G) -> Unit,
) {
    @Serializable
    private data class Record(
        val version: Int = 1,
        val phase: String,
        val active: String? = null,
        val proof: String? = null,
        val preparing: String? = null,
    )

    private val key = stringPreferencesKey("private-workspace-router-v1")
    private val control = Mutex()
    private val mutableGraph = MutableStateFlow<G?>(null)
    val graph = mutableGraph.asStateFlow()
    private var record: Record? = null
    private var closed: G? = null

    suspend fun start(): G {
        control.lock()
        try {
            mutableGraph.value?.let { return it }
            val stored = journal.data.first()[key]?.let { Json.decodeFromString<Record>(it) }
            check(
                stored == null || (
                    stored.version == 1 && stored.phase in setOf("PREPARING", "COMMITTED") &&
                        listOfNotNull(stored.active, stored.preparing).all { ID.matches(it) } &&
                        (stored.phase != "COMMITTED" || (stored.active != null && stored.proof != null && stored.preparing == null))
                    ),
            )
            record = stored
            val candidate = build(stored?.active)
            try {
                if (stored != null && (stored.phase != "COMMITTED" || stored.proof != owner().encoded)) {
                    boundary(candidate).quarantine()
                } else if (stored != null) {
                    boundary(candidate).reopenCommitted()
                } else {
                    boundary(candidate).reconcile()
                }
                bind(candidate)
                mutableGraph.value = candidate
                return candidate
            } catch (failure: Throwable) {
                withContext(NonCancellable) { close(candidate) }
                throw failure
            }
        } finally {
            control.unlock()
        }
    }

    suspend fun create(confirmed: Boolean, expectedEpoch: String): G {
        if (!control.tryLock()) throw PrivateStoreAccessDenied()
        try {
            val previous = mutableGraph.value ?: throw PrivateStoreAccessDenied()
            if (!confirmed || !signedIn()) throw PrivateStoreAccessDenied()
            val proof = owner()
            return boundary(previous).replaceWorkspace(confirmed, expectedEpoch) {
                // NonCancellable covers durable publication and resource ownership, not network I/O.
                withContext(NonCancellable) {
                    val id = Uuid.random().toString()
                    val preparing = Record(phase = "PREPARING", active = record?.active, proof = record?.proof, preparing = id)
                    write(preparing)
                    if (closed !== previous) {
                        close(previous)
                        closed = previous
                    }
                    val candidate = build(id)
                    try {
                        boundary(candidate).reconcile()
                        if (proof != owner() || !signedIn() || boundary(candidate).state.value.requiresConfirmation) {
                            throw PrivateStoreAccessDenied()
                        }
                        write(Record(phase = "COMMITTED", active = id, proof = proof.encoded))
                        if (proof != owner()) throw PrivateStoreAccessDenied()
                        // A committed but unbound candidate is never returned as success.
                        bind(candidate)
                        mutableGraph.value = candidate
                        closed = null
                        candidate
                    } catch (failure: Throwable) {
                        boundary(candidate).quarantine()
                        close(candidate)
                        throw failure
                    }
                }
            }
        } finally {
            control.unlock()
        }
    }

    private suspend fun write(next: Record) {
        journal.edit { it[key] = Json.encodeToString(next) }
        record = next
    }

    private companion object {
        val ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}
