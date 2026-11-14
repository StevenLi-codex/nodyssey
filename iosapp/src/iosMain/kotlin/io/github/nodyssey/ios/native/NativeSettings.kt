package io.github.nodyssey.ios.native

import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.OfflineSettings
import io.github.nodyssey.data.TitleBlockRule
import io.github.nodyssey.data.dns.problem
import io.github.nodyssey.data.imagehost.ImageHostException
import io.github.nodyssey.data.imagehost.ImageHostProvider
import io.github.nodyssey.data.imagehost.ImageHostRepository
import io.github.nodyssey.data.proxy.problem
import io.github.nodyssey.data.settings.AppLanguage
import io.github.nodyssey.data.settings.ColorSource
import io.github.nodyssey.data.settings.ComposerSurface
import io.github.nodyssey.data.settings.PaletteStyle
import io.github.nodyssey.data.settings.ReportCompareEntry
import io.github.nodyssey.data.settings.ReportFormat
import io.github.nodyssey.data.settings.SettingsRepository
import io.github.nodyssey.data.settings.ThemeMode
import io.github.nodyssey.data.sticker.GitHubRepoRef
import io.github.nodyssey.data.sticker.MySticker
import io.github.nodyssey.data.sticker.StickerCdn
import io.github.nodyssey.data.sticker.StickerCdnSettings
import io.github.nodyssey.data.sticker.StickerSourceError
import io.github.nodyssey.data.sticker.StickerSourceException
import io.github.nodyssey.data.sticker.extractStickerLinks
import io.github.nodyssey.data.sticker.folderGroupKey
import io.github.nodyssey.data.sticker.isStickerLink
import io.github.nodyssey.data.sticker.stickerNameFromUrl
import io.github.nodyssey.model.FeedSort
import io.github.nodyssey.model.TitleKeywordKind
import io.github.nodyssey.ui.composer.NodeSeekEmojiGroups
import io.github.plaza.designsys.editor.EmojiEntry
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

// Serialize read/modify/write drafts and selection-sensitive host calls. No duplicate state store.
private val settingsWriteLock = Mutex()
private val settingsCodec = Json { encodeDefaults = true }

internal suspend fun NativeContext.settingsRequest(operation: String, args: JsonObject): JsonElement? =
    if (operation.startsWith("imageHost.")) {
        settingsImageHostRequest(graph.imageHostRepository, operation, args)
    } else {
        settingsLockedRequest { settingsDispatch(operation, args) }
    }

/** Repository-only seam used by the app and iosTest; never creates a second lock or graph. */
internal suspend fun settingsImageHostRequest(repository: ImageHostRepository, operation: String, args: JsonObject): JsonElement? =
    settingsLockedRequest { settingsImageHostDispatch(repository, operation, args) }

private suspend fun settingsLockedRequest(dispatch: suspend () -> JsonElement?): JsonElement? =
    settingsWriteLock.withLock {
        try {
            dispatch()
        } catch (failure: ImageHostException) {
            throw NativeFailure(settingsImageHostErrorCode(failure.error))
        } catch (failure: StickerSourceException) {
            throw NativeFailure(
                when (failure.error) {
                    StickerSourceError.NotFound -> "STICKER_SOURCE_NOT_FOUND"
                    StickerSourceError.NoImages -> "STICKER_SOURCE_NO_IMAGES"
                    StickerSourceError.Network -> "NETWORK"
                    StickerSourceError.Unparsable -> "STICKER_SOURCE_UNPARSABLE"
                    is StickerSourceError.RateLimited -> "RATE_LIMITED"
                    is StickerSourceError.Http -> "HTTP"
                },
            )
        }
    }

private suspend fun settingsImageHostDispatch(repository: ImageHostRepository, operation: String, args: JsonObject): JsonElement? {
    when (operation) {
        "imageHost.login" -> throw NativeFailure("UNSUPPORTED")

        "imageHost.get" -> return (if ("provider" in args) repository.config(args.settingsEnum<ImageHostProvider>("provider")) else repository.current).first().settingsJson()

        "imageHost.select" -> {
            repository.select(args.settingsEnum<ImageHostProvider>("provider"))
            return repository.current.first().settingsJson()
        }

        "imageHost.save" -> {
            val provider = args.settingsEnum<ImageHostProvider>("provider")
            val draft = settingsImageHostDraft(args, repository.config(provider).first())
            require(draft.problem() == null) { "Invalid image host configuration" }
            repository.save(draft)
            val saved = repository.config(provider).first()
            if (draft.token.trim() != saved.token || draft.custom.headerValue.trim() != saved.custom.headerValue || draft.custom.formFields.trim() != saved.custom.formFields) {
                throw NativeFailure("SECRET_NOT_STORED")
            }
            return saved.settingsJson()
        }

        "imageHost.disconnect" -> {
            val provider = args.settingsEnum<ImageHostProvider>("provider")
            repository.disconnect(provider)
            return repository.config(provider).first().settingsJson()
        }

        "imageHost.images", "imageHost.test" -> {
            val provider = repository.current.first().provider
            // Optional for read-only callers; Media binds every displayed gallery to its provider.
            if ("expectedProvider" in args && args.settingsEnum<ImageHostProvider>("expectedProvider") != provider) throw NativeFailure("SOURCE_CHANGED")
            if (!provider.browsable) throw NativeFailure("UNSUPPORTED")
            return settingsValue(repository.images().map { it.settingsJson() })
        }

        "imageHost.delete" -> {
            val id = args.settingsString("id")
            val expectedProvider = args.settingsEnum<ImageHostProvider>("expectedProvider")
            // Validate the displayed provider inside settingsWriteLock, before any host I/O.
            // Native selection/configuration writes share this lock through listing and deletion.
            if (repository.current.first().provider != expectedProvider) throw NativeFailure("SOURCE_CHANGED")
            // The deletion token never leaves Kotlin, including for hosts where it differs from id.
            val image = repository.images().firstOrNull { it.id == id } ?: throw NativeFailure("NOT_FOUND")
            repository.delete(image)
            return JsonNull
        }
    }
    return null
}

private suspend fun NativeContext.settingsDispatch(operation: String, args: JsonObject): JsonElement? {
    val settings = graph.settingsRepository
    when (operation) {
        "settings.get" -> return settingsSnapshot()

        "settings.set" -> {
            settingsApply(settings, args)
            if (args.settingsString("key") == "readHistoryLimit") graph.postRepository.trimReadHistory()
            return settingsSnapshot()
        }

        "settings.theme.save" -> {
            settings.saveTheme(args.settingsString("name"), args.settingsInt("color"))
            return settingsSnapshot()
        }

        "settings.theme.delete" -> {
            settings.deleteSavedTheme(args.settingsInt("color"))
            return settingsSnapshot()
        }

        "settings.homeBoards" -> {
            settings.setHomeBoardArrangement(args.settingsStrings("order"), args.settingsStrings("disabled").toSet())
            return settingsSnapshot()
        }

        "settings.toolbar" -> {
            settings.setComposerToolbar(args.settingsEnum<ComposerSurface>("surface"), args.settingsStrings("actions"))
            return settingsSnapshot()
        }

        "settings.capabilities" -> return settingsCapabilities()

        "settings.metadata" -> return settingsMetadata()

        "settings.terms", "settings.privacy" -> return graph.termsRepository.terms().settingsJson()

        "proxy.get" -> return graph.proxySettings.config.first().settingsJson()

        "proxy.save" -> {
            val draft = settingsProxyDraft(args, graph.proxySettings.config.first())
            graph.proxySettings.save(draft)
            val persisted = graph.proxySettings.config.first()
            if (draft.password.isNotEmpty() && persisted.password != draft.password) throw NativeFailure("SECRET_NOT_STORED")
            return persisted.settingsJson()
        }

        "proxy.enabled" -> {
            val enabled = args.settingsBoolean("enabled")
            require(graph.proxySettings.config.first().copy(enabled = enabled).problem() == null) { "Invalid proxy configuration" }
            graph.proxySettings.setEnabled(enabled)
            return graph.proxySettings.config.first().settingsJson()
        }

        "proxy.test" -> {
            val result = graph.proxyConnectionTester.test()
            return settingsObject("connected" to result.isSuccess, "kind" to result.exceptionOrNull()?.let { graph.proxyConnectionTester.classify(it).kind })
        }

        "doh.get" -> return graph.doh.settings.config.first().settingsJson(graph.doh.capabilities)

        "doh.save" -> {
            val doh = graph.doh
            doh.settings.save(settingsDohDraft(args, doh.settings.config.first(), doh.capabilities))
            return doh.settings.config.first().settingsJson(doh.capabilities)
        }

        "doh.enabled" -> {
            val doh = graph.doh
            val enabled = args.settingsBoolean("enabled")
            require(doh.settings.config.first().copy(enabled = enabled).problem() == null) { "No DNS server selected" }
            doh.settings.setEnabled(enabled)
            return doh.settings.config.first().settingsJson(doh.capabilities)
        }

        "doh.test" -> {
            val result = graph.doh.tester.resolve().getOrThrow()
            return settingsObject("host" to result.host, "addresses" to result.addresses, "elapsedMillis" to result.elapsedMillis)
        }

        "settings.changelog" -> return releaseNotesRequest(args)

        "network.diagnostics", "settings.crashReport" -> throw NativeFailure("UNSUPPORTED")

        "offline.get" -> return offlineFlow().first()

        "offline.settings" -> {
            val old = graph.offlineLibrary.settings.first()
            val draft = old.copy(
                wifiOnly = if ("wifiOnly" in args) args.settingsBoolean("wifiOnly") else old.wifiOnly,
                includeImages = if ("includeImages" in args) args.settingsBoolean("includeImages") else old.includeImages,
                autoSyncReplies = if ("autoSyncReplies" in args) args.settingsBoolean("autoSyncReplies") else old.autoSyncReplies,
                retentionDays = if ("retentionDays" in args) args.settingsInt("retentionDays") else old.retentionDays,
            )
            require(draft.retentionDays in OfflineSettings.RETENTION_CHOICES) { "Invalid retention policy" }
            graph.offlineLibrary.updateSettings(draft)
            return offlineFlow().first()
        }

        "offline.download" -> {
            graph.offlineLibrary.download(args.settingsIds())
            return offlineFlow().first()
        }

        "offline.cancel" -> {
            graph.offlineLibrary.cancel(args.settingsId("postId"))
            return offlineFlow().first()
        }

        "offline.clear" -> {
            graph.offlineLibrary.clearAll()
            return offlineFlow().first()
        }

        "offline.estimate" -> return settingsObject("bytes" to graph.offlineLibrary.estimateBytes(args.settingsIds()))

        "cache.size" -> return settingsObject("sizeBytes" to graph.appCacheStore.sizeBytes())

        "cache.clear" -> {
            val session = graph.sessionRepository.peek()
            graph.postRepository.clearCache(session.isSignedIn, session.fingerprint)
            graph.appCacheStore.clear()
            return settingsObject("sizeBytes" to graph.appCacheStore.sizeBytes())
        }

        "keywords.get" -> return settingsValue(graph.titleKeywordStore.current(args.settingsEnum<TitleKeywordKind>("kind")))

        "keywords.add", "keywords.remove" -> {
            val kind = args.settingsEnum<TitleKeywordKind>("kind")
            val text = args.settingsString("text")
            val store = graph.titleKeywordStore
            if (operation == "keywords.add") {
                val added = if (kind == TitleKeywordKind.ALERT) store.add(kind, text) else store.addBlockRule(text, kind == TitleKeywordKind.BLOCK_REGEX)
                require(added) { "Invalid keyword or regular expression" }
            } else if (kind == TitleKeywordKind.ALERT) {
                store.remove(kind, text)
            } else {
                store.removeBlockRule(TitleBlockRule(text, kind == TitleKeywordKind.BLOCK_REGEX))
            }
            return settingsValue(store.current(kind))
        }

        "notes.get" -> return notesFlow().first()

        "notes.set" -> {
            graph.userNoteStore.setNote(args.settingsId("uid"), args.settingsString("note"))
            return notesFlow().first()
        }

        "tracked.get" -> return trackedFlow().first()

        "tracked.add" -> {
            val count = if (args["commentCount"] == null || args["commentCount"] == JsonNull) null else args.settingsInt("commentCount").also { require(it >= 0) }
            val added = graph.trackedThreadStore.track(
                args.settingsId("postId"),
                args.settingsString("title"),
                count,
                args.settingsOptionalString("authorName"),
                args.settingsOptionalString("categoryTitle"),
                args.settingsOptionalString("categorySlug"),
            )
            if (!added) throw NativeFailure("TRACKED_LIMIT")
            return trackedFlow().first()
        }

        "tracked.remove" -> {
            graph.trackedThreadStore.untrack(args.settingsId("postId"))
            return trackedFlow().first()
        }

        "reports.get" -> return reportsFlow().first()

        "reports.add", "reports.remove" -> {
            val entry = settingsCodec.decodeFromJsonElement<ReportCompareEntry>(args.settingsObjectAt("entry"))
            if (operation == "reports.add") graph.reportCompareStore.add(entry) else graph.reportCompareStore.remove(entry)
            return reportsFlow().first()
        }
    }
    return settingsStickerRequest(operation, args)
}

private suspend fun NativeContext.settingsStickerRequest(operation: String, args: JsonObject): JsonElement? {
    // Do not initialize a repository (and its scope worker) while dispatching unrelated operations.
    if (!operation.startsWith("stickers.")) return null
    val library = graph.stickerLibrary
    when (operation) {
        "stickers.get" -> return stickersFlow().first()

        "stickers.add" -> {
            val stickers = args.settingsArray("stickers").map {
                val row = it as? JsonObject ?: throw IllegalArgumentException("Invalid sticker")
                MySticker(row.settingsString("url"), row.settingsString("name")).also { sticker -> require(isStickerLink(sticker.url)) { "HTTPS required" } }
            }
            return settingsObject("addedUrls" to library.add(stickers))
        }

        "stickers.addLinks" -> return settingsObject("addedUrls" to library.add(extractStickerLinks(args.settingsString("text")).map { MySticker(it, stickerNameFromUrl(it)) }))

        "stickers.remove" -> library.remove(args.settingsStrings("urls"))

        "stickers.rename" -> {
            val name = args.settingsString("name")
            require(name.isNotBlank()) { "Empty sticker name" }
            library.rename(args.settingsString("url"), name)
        }

        "stickers.moveToTop" -> library.moveToTop(args.settingsStrings("urls"))

        "stickers.reorder" -> {
            val urls = args.settingsStrings("urls")
            require(urls.distinct().size == urls.size && urls.toSet() == library.mine.first().map { it.url }.toSet()) { "Incomplete sticker order" }
            library.reorder(urls)
        }

        "stickers.groups.reorder" -> library.reorderGroups(args.settingsStrings("keys").distinct())

        "stickers.groups.hidden" -> library.setGroupHidden(args.settingsString("key"), args.settingsBoolean("hidden"))

        "stickers.cdn" -> {
            val cdn = args.settingsEnum<StickerCdn>("cdn")
            val base = args.settingsOptionalString("customBase") ?: library.cdn.first().customBase
            require(cdn != StickerCdn.CUSTOM || StickerCdnSettings(cdn, base).normalizedCustomBase() != null) { "Invalid CDN base" }
            if ("customBase" in args) library.setCustomCdnBase(base)
            library.setCdn(cdn)
        }

        "stickers.export" -> return settingsObject("text" to library.exportBackup())

        "stickers.import" -> {
            val result = library.importBackup(args.settingsString("text")) ?: throw NativeFailure("INVALID_BACKUP")
            return settingsObject("stickers" to result.stickers, "folders" to result.folders, "failedRepos" to result.failedRepos)
        }

        "stickers.inspect" -> return library.inspect(args.settingsRepo()).settingsJson()

        "stickers.subscribe" -> {
            val listing = library.inspect(args.settingsRepo())
            if (listing.sha != args.settingsString("expectedSha")) throw NativeFailure("SOURCE_CHANGED")
            val paths = args.settingsStrings("paths").toSet()
            require(paths.isNotEmpty() && paths.all { path -> listing.folders.any { it.path == path } }) { "Invalid folders" }
            library.subscribe(listing, paths)
        }

        "stickers.unsubscribe" -> library.unsubscribe(args.settingsString("slug"))

        "stickers.applyUpdate" -> library.applyUpdate(args.settingsString("slug"))

        "stickers.folders.hidden" -> library.setFolderHidden(args.settingsString("slug"), args.settingsString("path"), args.settingsBoolean("hidden"))

        "stickers.folders.reorder" -> library.reorderFolders(args.settingsString("slug"), args.settingsStrings("paths"))

        "stickers.checkUpdates" -> return settingsObject("error" to library.checkForUpdates(args.settingsBoolean("force"))?.settingsJson())

        "stickers.probe" -> {
            val url = args.settingsString("url")
            require(isStickerLink(url)) { "HTTPS required" }
            return library.probe(url).settingsJson()
        }

        "stickers.probeMine" -> library.probeMine()

        "stickers.measure" -> return settingsObject("elapsedMillis" to library.measure(args.settingsEnum<StickerCdn>("cdn")))

        "stickers.upload" -> {
            library.upload(settingsPickedImages(args), args.settingsBoolean("keepOriginal"))
        }

        "stickers.retryUpload" -> library.retryUpload(args.settingsString("id"))

        "stickers.clearFinishedUploads" -> library.clearFinishedUploads()

        else -> return null
    }
    return stickersFlow().first()
}

internal fun NativeContext.settingsObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when (operation) {
    "settings.observe" -> combine(graph.settingsRepository.settings, graph.settingsRepository.showBlockedContent) { settings, blocked -> settings.settingsJson(blocked) }
    "proxy.observe" -> graph.proxySettings.config.map { it.settingsJson() }
    "doh.observe" -> graph.doh.settings.config.map { it.settingsJson(graph.doh.capabilities) }
    "imageHost.observe" -> imageHostFlow(args)
    "offline.observe" -> offlineFlow()
    "stickers.observe" -> stickersFlow()
    "keywords.observe" -> graph.titleKeywordStore.keywords(args.settingsEnum<TitleKeywordKind>("kind")).map { settingsValue(it) }
    "notes.observe" -> notesFlow()
    "tracked.observe" -> trackedFlow()
    "reports.observe" -> reportsFlow()
    else -> null
}

private suspend fun NativeContext.settingsSnapshot(): JsonElement =
    graph.settingsRepository.settings.first().settingsJson(graph.settingsRepository.showBlockedContent.value)

private fun NativeContext.imageHostFlow(args: JsonObject): Flow<JsonElement> =
    (if ("provider" in args) graph.imageHostRepository.config(args.settingsEnum<ImageHostProvider>("provider")) else graph.imageHostRepository.current).map { it.settingsJson() }

private fun NativeContext.offlineFlow(): Flow<JsonElement> =
    combine(graph.offlineLibrary.settings, graph.offlineLibrary.usage, graph.offlineLibrary.states) { settings, usage, states ->
        settingsObject("isAvailable" to graph.offlineLibrary.isAvailable, "settings" to settings.settingsJson(), "usage" to usage.settingsJson(), "states" to states.entries.sortedBy { it.key }.map { (id, state) -> state.settingsJson(id) })
    }

private fun NativeContext.notesFlow(): Flow<JsonElement> = graph.userNoteStore.notes.map { notes ->
    settingsValue(notes.entries.sortedBy { it.key }.map { (uid, note) -> settingsObject("uid" to uid, "note" to note) })
}

private fun NativeContext.trackedFlow(): Flow<JsonElement> = graph.trackedThreadStore.tracked.map { rows -> settingsValue(rows.map { it.settingsJson() }) }

private fun NativeContext.reportsFlow(): Flow<JsonElement> = graph.reportCompareStore.entries.map { settingsCodec.encodeToJsonElement(it) }

private fun NativeContext.stickersFlow(): Flow<JsonElement> {
    val library = graph.stickerLibrary
    val saved = combine(library.mine, library.subscriptions, library.cdn, library.groupLayout) { mine, subscriptions, cdn, layout ->
        settingsObject(
            "mine" to mine.map { settingsObject("url" to it.url, "name" to it.name) },
            "siteGroups" to settingsSiteGroups(),
            "subscriptions" to subscriptions.map { it.settingsJson(cdn) },
            "cdn" to settingsObject("cdn" to cdn.cdn, "customBase" to cdn.customBase, "effective" to cdn.effective),
            "groupLayout" to settingsObject("order" to layout.order, "hidden" to layout.hidden),
            "arrangedGroupKeys" to layout.arrange(listOf("mine") + subscriptions.flatMap { subscription -> subscription.folders.map { folderGroupKey(subscription.slug, it.path) } } + NodeSeekEmojiGroups.map { it.key }),
        )
    }
    return combine(saved, library.uploads, library.linkProbes, library.sourceErrors) { snapshot, uploads, probes, errors ->
        JsonObject(
            snapshot + mapOf(
                "uploads" to settingsValue(uploads.map { it.settingsJson() }),
                "linkProbes" to settingsValue(probes.map { (url, result) -> settingsObject("url" to url, "result" to result.settingsJson()) }),
                "sourceErrors" to settingsValue(errors.map { (slug, error) -> settingsObject("slug" to slug, "error" to error.settingsJson()) }),
            ),
        )
    }
}

/** Catalogue only: never invokes a Compose title lambda or embeds a Compose view. */
internal fun settingsSiteGroups(): List<JsonObject> = NodeSeekEmojiGroups.map { group ->
    settingsObject(
        "key" to group.key,
        "entries" to group.entries.map { entry ->
            when (entry) {
                is EmojiEntry.Unicode -> settingsObject("type" to "Unicode", "character" to entry.character)
                is EmojiEntry.Sticker -> settingsObject("type" to "Sticker", "name" to entry.name, "shortcode" to entry.shortcode, "url" to entry.url)
            }
        },
    )
}

private fun JsonObject.settingsId(key: String): Long = settingsLong(key).also { require(it > 0) { "Invalid identity" } }

private fun JsonObject.settingsIds(): List<Long> = settingsArray("postIds").map { settingsObject("id" to it).settingsId("id") }.distinct().also { require(it.isNotEmpty()) { "No threads selected" } }

private fun JsonObject.settingsRepo(): GitHubRepoRef = GitHubRepoRef.parse(settingsString("url")) ?: throw IllegalArgumentException("Invalid GitHub repository")

internal suspend fun settingsApply(repository: SettingsRepository, args: JsonObject) {
    // One property per request: validate before writing; no half-applied multi-field patch.
    when (args.settingsString("key")) {
        "themeMode" -> repository.setThemeMode(args.settingsEnum<ThemeMode>("value"))

        "appLanguage" -> repository.setAppLanguage(args.settingsEnum<AppLanguage>("value"))

        "colorSource" -> {
            val source = args.settingsEnum<ColorSource>("value")
            if (source == ColorSource.WALLPAPER) throw NativeFailure("UNSUPPORTED")
            repository.setColorSource(source)
        }

        "presetId" -> repository.setPresetId(args.settingsString("value"))

        "seedColor" -> repository.setSeedColor(args.settingsInt("value"))

        "paletteStyle" -> repository.setPaletteStyle(args.settingsEnum<PaletteStyle>("value"))

        "fontScale" -> repository.setFontScale(args.settingsFloat("value"))

        "oneHandMode" -> repository.setOneHandMode(args.settingsBoolean("value"))

        "einkMode" -> repository.setEinkMode(args.settingsBoolean("value"))

        "imagesOnWifiOnly" -> repository.setImagesOnWifiOnly(args.settingsBoolean("value"))

        "stickerUniformSize" -> repository.setStickerUniformSize(args.settingsBoolean("value"))

        "stickerSize" -> repository.setStickerSize(args.settingsInt("value"))

        "reportFormat" -> repository.setReportFormat(args.settingsEnum<ReportFormat>("value"))

        "feedSort" -> repository.setFeedSort(args.settingsEnum<FeedSort>("value"))

        "homePageBar" -> repository.setHomePageBar(args.settingsBoolean("value"))

        "readHistoryLimit" -> repository.setReadHistoryLimit(args.settingsInt("value"))

        "onboardingSeen" -> repository.setOnboardingSeen(args.settingsBoolean("value"))

        "oneHandTipDismissed" -> {
            require(args.settingsBoolean("value")) { "Dismissal must be true" }
            repository.dismissOneHandTip()
        }

        "showBlockedContent" -> repository.setShowBlockedContent(args.settingsBoolean("value"))

        // Android-only background polling/update/wallpaper/clipboard capabilities must not pretend
        // to work just because DataStore would happily store a boolean.
        else -> throw NativeFailure("UNSUPPORTED_SETTING")
    }
}

private fun NativeContext.settingsCapabilities(): JsonObject = settingsCapabilities(graph.offlineLibrary.isAvailable, graph.networkDiagnostics != null)

internal fun settingsCapabilities(offlineAvailable: Boolean, networkDiagnosticsAvailable: Boolean): JsonObject = settingsObject(
    "offline" to offlineAvailable, "networkDiagnostics" to networkDiagnosticsAvailable,
    "notificationPolling" to false, "appUpdates" to false, "wallpaperColors" to false,
    "clipboardPostPrompt" to false, "imageHostPasswordLogin" to false,
    "imagesOnWifiOnly" to true, "releaseNotes" to true, "crashReports" to false,
    "offlineImageReading" to true,
    "imageHosts" to ImageHostProvider.entries.map { settingsObject("provider" to it, "needsSiteUrl" to it.needsSiteUrl, "browsable" to it.browsable, "connectionTest" to it.browsable) },
    "retentionChoices" to OfflineSettings.RETENTION_CHOICES,
)

private fun NativeContext.settingsMetadata(): JsonObject = settingsObject(
    "label" to graph.appVersion.label, "name" to graph.appVersion.name, "code" to graph.appVersion.code,
    "project" to "https://github.com/5151561/nodyssey",
    "issues" to "https://github.com/5151561/nodyssey/issues",
    "changelog" to "https://github.com/5151561/nodyssey/releases",
    "license" to "https://github.com/5151561/nodyssey/blob/main/LICENSE",
    "terms" to (NodeSeekSite.BASE_URL + NodeSeekSite.TERMS_OF_SERVICE_PATH),
    "help" to "https://github.com/5151561/nodyssey",
    "telegramChannel" to "https://t.me/nodyssey_official",
    "telegramGroup" to "https://t.me/+0mY1RaPADJMwNTdl",
    "licenses" to listOf(
        settingsObject("name" to "AndroidX · Jetpack Compose", "license" to "Apache License 2.0", "url" to "https://android.googlesource.com/platform/frameworks/support"),
        settingsObject("name" to "Kotlin · Coroutines · Serialization", "license" to "Apache License 2.0", "url" to "https://github.com/JetBrains/kotlin"),
        settingsObject("name" to "OkHttp", "license" to "Apache License 2.0", "url" to "https://github.com/square/okhttp"),
        settingsObject("name" to "Coil", "license" to "Apache License 2.0", "url" to "https://github.com/coil-kt/coil"),
        settingsObject("name" to "Ksoup", "license" to "MIT License", "url" to "https://github.com/fleeksoft/ksoup"),
        settingsObject("name" to "kotlinx-datetime", "license" to "Apache License 2.0", "url" to "https://github.com/Kotlin/kotlinx-datetime"),
    ),
)
