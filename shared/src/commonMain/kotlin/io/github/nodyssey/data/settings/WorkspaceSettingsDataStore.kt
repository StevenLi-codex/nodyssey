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
                (before.asMap().keys + after.asMap().keys).filter { it.name in PUBLIC_KEYS }.forEach { key ->
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
        source.asMap().filterKeys { (it.name !in PUBLIC_KEYS) == private }.forEach { (key, value) ->
            @Suppress("UNCHECKED_CAST")
            val typed = key as Preferences.Key<Any>
            result[typed] = value
        }
        return result
    }

    companion object {
        // Positive allowlist: unknown/future keys are local, never exposed from the old mixed store.
        val PUBLIC_KEYS: Set<String> = setOf(
            "theme_mode", "app_language", "dynamic_color", "color_source", "preset_id", "seed_color",
            "wallpaper_seed", "wallpaper_system_palette", "wallpaper_auto_update", "palette_style", "saved_themes",
            "font_scale", "one_hand_mode", "eink_mode", "sticker_uniform_size", "sticker_size_sp",
            "images_on_wifi_only", "report_format", "hidden_home_boards", "home_board_order", "disabled_home_boards",
            "hidden_home_boards-deepflood", "home_board_order-deepflood", "disabled_home_boards-deepflood",
            "post_toolbar_actions", "reply_toolbar_actions", "message_toolbar_actions", "feed_sort", "home_page_bar",
            "clipboard_post_prompt", "onboarding_seen", "one_hand_tip_dismissed", "holiday_theme",
            "notifications_enabled", "notification_poll_minutes", "notifications_wifi_only", "notification_quiet_hours",
            "notify_interactions", "notify_mentions", "notify_replies", "notify_messages", "notify_keyword_alerts",
            "notify_tracked_threads", "read_history_limit", "update_check_on_launch", "update_dev_channel",
            "sticker_cdn", "sticker_cdn_custom", "sticker_group_order", "sticker_groups_hidden",
        )
    }
}
