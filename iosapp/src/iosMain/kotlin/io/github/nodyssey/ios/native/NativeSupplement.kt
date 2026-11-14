package io.github.nodyssey.ios.native

import io.github.nodyssey.core.ActiveSite
import io.github.nodyssey.core.Site
import io.github.nodyssey.core.report.QualityReportParser
import io.github.nodyssey.data.settings.SettingsRepository
import io.github.nodyssey.ios.NodysseyApp
import io.github.nodyssey.model.FeedSort
import io.github.nodyssey.model.SearchHistoryEntry
import io.github.nodyssey.model.SearchTarget
import io.github.plaza.core.ansi.AnsiDecoder
import io.github.plaza.core.ansi.AnsiSpan
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import platform.Foundation.NSUserDefaults

private val supplementCodec = Json { encodeDefaults = true }

internal suspend fun NativeContext.supplementRequest(operation: String, args: JsonObject): JsonElement? = when (operation) {
    "reports.parse" -> supplementParseReport(args)

    "app.foreground" -> {
        NodysseyApp.nativeForeground()
        JsonNull
    }

    "site.get", "site.select" -> supplementSiteRequest(
        operation,
        args,
        ActiveSite.current,
        // Same platform SSOT/key as IosActiveSite; its store() is module-internal to :ui.
        // Do not call install(): the running graph must never change sites underneath readers.
        { NSUserDefaults.standardUserDefaults.stringForKey("active_site") },
        { NSUserDefaults.standardUserDefaults.setObject(it, "active_site") },
    )

    else -> supplementSettingsRequest(graph.settingsRepository, operation, args)
}

internal fun NativeContext.supplementObserve(operation: String): Flow<JsonElement>? = when (operation) {
    "search.history" -> supplementHistory(graph.settingsRepository)
    "boards.recent" -> supplementRecentBoards(graph.settingsRepository)
    else -> null
}

internal suspend fun supplementForeground(ready: suspend () -> Unit, onLaunch: () -> Unit) {
    ready()
    kotlinx.coroutines.currentCoroutineContext().ensureActive()
    onLaunch()
}

internal fun supplementSiteRequest(
    operation: String,
    args: JsonObject,
    current: Site,
    readStored: () -> String?,
    store: (String) -> Unit,
): JsonObject? {
    when (operation) {
        "site.get" -> Unit

        "site.select" -> {
            val chosen = args.settingsEnum<Site>("site")
            store(chosen.storedValue)
            check(readStored() == chosen.storedValue) { "Site choice was not stored" }
        }

        else -> return null
    }
    val selected = Site.ofStoredValue(readStored())
    return settingsObject(
        "current" to current,
        "selected" to selected,
        "requiresRestart" to (current != selected),
        "sites" to Site.entries.map {
            settingsObject(
                "id" to it,
                "displayName" to it.displayName,
                "origin" to it.origin,
                "hosts" to it.hosts.toList(),
                "oneTapSignInPath" to it.oneTapSignIn?.path,
                "oneTapProviderName" to it.oneTapSignIn?.providerName,
            )
        },
    )
}

internal suspend fun supplementSettingsRequest(repository: SettingsRepository, operation: String, args: JsonObject): JsonElement? {
    when (operation) {
        "search.history.record" -> repository.addSearchHistory(args.supplementSearchEntry())

        "search.history.remove" -> repository.removeSearchHistory(args.supplementSearchEntry())

        "search.history.clear" -> repository.clearSearchHistory(args.settingsEnum<SearchTarget>("target"))

        "search.history.get" -> Unit

        "boards.recent.record" -> {
            repository.recordRecentBoard(args.settingsOptionalString("categorySlug"))
            return supplementRecentBoards(repository).first()
        }

        "boards.recent.get" -> return supplementRecentBoards(repository).first()

        else -> return null
    }
    return supplementHistory(repository).first()
}

internal fun supplementRecentBoards(repository: SettingsRepository): Flow<JsonElement> = repository.settings.map { supplementCodec.encodeToJsonElement(it.recentBoards) }

internal fun supplementHistory(repository: SettingsRepository): Flow<JsonElement> = repository.settings.map { settings ->
    JsonArray(settings.searchHistory.map { settingsObject("query" to it.query, "target" to it.target, "categorySlug" to it.categorySlug, "sort" to it.sort) })
}

private fun JsonObject.supplementSearchEntry(): SearchHistoryEntry = SearchHistoryEntry(
    query = settingsString("query"),
    target = settingsEnum<SearchTarget>("target"),
    categorySlug = settingsOptionalString("categorySlug"),
    sort = if ("sort" in this) settingsEnum<FeedSort>("sort") else FeedSort.POST_TIME,
)

internal fun supplementParseReport(args: JsonObject): JsonElement {
    val code = args.settingsString("code")
    val report = if ("spans" in args) {
        QualityReportParser.parse(code, supplementCodec.decodeFromJsonElement<List<AnsiSpan>>(args.settingsArray("spans")))
    } else {
        val decoded = AnsiDecoder.decode(code)
        QualityReportParser.parse(decoded.text, decoded.spans)
    }
    return report?.let { supplementCodec.encodeToJsonElement(it) } ?: JsonNull
}
