package io.github.nodyssey.data.settings

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** An iOS opt-in view, not a second DataStore over the global file. Android is unchanged.
 * Global keys retain their original SSOT. No private value is copied from the legacy store.
 * A transform may change one partition only; there is no pretend cross-file transaction.
 */
class WorkspaceSettingsDataStore(
    private val global: DataStore<Preferences>,
    private val privateStore: DataStore<Preferences>,
    private val mutex: Mutex,
) : DataStore<Preferences> {
    override val data: Flow<Preferences> = combine(global.data, privateStore.data, ::merge)

    override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences = mutex.withLock {
        val publicBefore = global.data.first()
        val privateBefore = privateStore.data.first()
        val before = merge(publicBefore, privateBefore)
        val after = transform(before)
        val privateChanged = partition(before, true) != partition(after, true)
        val publicChanged = partition(before, false) != partition(after, false)
        check(!(privateChanged && publicChanged)) { "Cross-partition preference update is not atomic" }
        if (privateChanged) privateStore.updateData { partition(after, true) }
        if (publicChanged) {
            global.updateData { current ->
                val result = current.toMutablePreferences()
                // Apply only this transform's diff, retaining concurrent global writers and legacy bytes.
                (before.asMap().keys + after.asMap().keys).filter { it.name !in PRIVATE_KEYS }.forEach { key ->
                    if (before.asMap()[key] != after.asMap()[key]) {
                        @Suppress("UNCHECKED_CAST")
                        val typed = key as Preferences.Key<Any>
                        val value = after.asMap()[key]
                        if (value == null) result.remove(typed) else result[typed] = value
                    }
                }
                result
            }
        }
        merge(global.data.first(), privateStore.data.first())
    }

    private fun merge(global: Preferences, local: Preferences): Preferences {
        val result = partition(global, false).toMutablePreferences()
        partition(local, true).asMap().forEach { (key, value) ->
            @Suppress("UNCHECKED_CAST")
            val typed = key as Preferences.Key<Any>
            result[typed] = value
        }
        return result
    }

    private fun partition(source: Preferences, private: Boolean): Preferences {
        val result = emptyPreferences().toMutablePreferences()
        source.asMap().filterKeys { (it.name in PRIVATE_KEYS) == private }.forEach { (key, value) ->
            @Suppress("UNCHECKED_CAST")
            val typed = key as Preferences.Key<Any>
            result[typed] = value
        }
        return result
    }

    companion object {
        val PRIVATE_KEYS: Set<String> = setOf(
            "search_history_v3", "recent_searches", "recent_boards", "report_compare_basket",
            "notification_seen_replies", "notification_seen_mentions", "notification_seen_messages", "notification_seen_overlap",
            "last_clipboard_post_link", "keyword_alert_last_post_id", "keyword_alert_last_post_id-deepflood",
        )
    }
}
