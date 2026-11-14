package io.github.nodyssey.ios.native

import io.github.nodyssey.data.OfflineSettings
import io.github.nodyssey.data.OfflineState
import io.github.nodyssey.data.OfflineUsage
import io.github.nodyssey.data.TrackedThread
import io.github.nodyssey.data.composer.PickedImage
import io.github.nodyssey.data.dns.DohCapabilities
import io.github.nodyssey.data.dns.DohConfig
import io.github.nodyssey.data.dns.DohProvider
import io.github.nodyssey.data.dns.DohServer
import io.github.nodyssey.data.dns.dohServerProblem
import io.github.nodyssey.data.dns.problem
import io.github.nodyssey.data.imagehost.HostedImage
import io.github.nodyssey.data.imagehost.ImageHostConfig
import io.github.nodyssey.data.imagehost.ImageHostError
import io.github.nodyssey.data.proxy.ProxyConfig
import io.github.nodyssey.data.proxy.ProxyScope
import io.github.nodyssey.data.proxy.ProxyType
import io.github.nodyssey.data.proxy.problem
import io.github.nodyssey.data.settings.UserSettings
import io.github.nodyssey.data.sticker.LinkProbe
import io.github.nodyssey.data.sticker.RepoListing
import io.github.nodyssey.data.sticker.StickerCdnSettings
import io.github.nodyssey.data.sticker.StickerSourceError
import io.github.nodyssey.data.sticker.StickerSubscription
import io.github.nodyssey.data.sticker.StickerUpload
import io.github.nodyssey.data.sticker.folderGroupKey
import io.github.nodyssey.data.sticker.stickerNameFromPath
import io.github.nodyssey.model.TermsBlock
import io.github.nodyssey.model.TermsDocument
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/** Deliberately no reflection/toString fallback: credentials must be mapped explicitly. */
internal fun settingsValue(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Enum<*> -> JsonPrimitive(value.name)
    is Iterable<*> -> JsonArray(value.map(::settingsValue))
    else -> error("Unmapped settings value")
}

internal fun settingsObject(vararg fields: Pair<String, Any?>): JsonObject =
    JsonObject(fields.associate { it.first to settingsValue(it.second) })

internal fun JsonObject.settingsString(key: String): String =
    (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
        ?: throw IllegalArgumentException("Invalid string argument")

internal fun JsonObject.settingsOptionalString(key: String): String? =
    if (get(key) == null || get(key) == JsonNull) null else settingsString(key)

internal fun JsonObject.settingsBoolean(key: String): Boolean =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull
        ?: throw IllegalArgumentException("Invalid boolean argument")

internal fun JsonObject.settingsInt(key: String): Int =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
        ?: throw IllegalArgumentException("Invalid integer argument")

internal fun JsonObject.settingsLong(key: String): Long =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
        ?: throw IllegalArgumentException("Invalid integer argument")

internal fun JsonObject.settingsFloat(key: String): Float =
    (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.doubleOrNull
        ?.toFloat()?.takeIf { it.isFinite() } ?: throw IllegalArgumentException("Invalid number argument")

internal fun JsonObject.settingsArray(key: String): JsonArray =
    get(key) as? JsonArray ?: throw IllegalArgumentException("Invalid array argument")

internal fun JsonObject.settingsStrings(key: String): List<String> = settingsArray(key).map {
    (it as? JsonPrimitive)?.takeIf { value -> value.isString }?.content
        ?: throw IllegalArgumentException("Invalid string array")
}

internal fun JsonObject.settingsObjectAt(key: String): JsonObject =
    get(key) as? JsonObject ?: throw IllegalArgumentException("Invalid object argument")

internal inline fun <reified T : Enum<T>> JsonObject.settingsEnum(key: String): T =
    enumValues<T>().firstOrNull { it.name == settingsString(key) }
        ?: throw IllegalArgumentException("Invalid enum argument")

internal fun settingsPickedImages(args: JsonObject): List<PickedImage> = args.settingsArray("images").map {
    val row = it as? JsonObject ?: throw IllegalArgumentException("Invalid picked image")
    val source = row.settingsString("source")
    require(source.startsWith("file:///") && source.length > "file:///".length) { "Local picked image required" }
    PickedImage(source, row.settingsString("name"))
}.also { require(it.isNotEmpty()) { "No images selected" } }

internal fun settingsProxyDraft(args: JsonObject, previous: ProxyConfig): ProxyConfig = previous.copy(
    enabled = if ("enabled" in args) args.settingsBoolean("enabled") else previous.enabled,
    type = if ("type" in args) args.settingsEnum<ProxyType>("type") else previous.type,
    host = if ("host" in args) args.settingsString("host").trim() else previous.host,
    port = if ("port" in args) args.settingsInt("port") else previous.port,
    username = if ("username" in args) args.settingsString("username") else previous.username,
    password = if ("password" in args) args.settingsString("password") else previous.password,
    scope = if ("scope" in args) args.settingsEnum<ProxyScope>("scope") else previous.scope,
).also { require(it.problem() == null) { "Invalid proxy configuration" } }

internal fun ProxyConfig.settingsJson(): JsonObject = settingsObject(
    "enabled" to enabled,
    "type" to type,
    "host" to host,
    "port" to port,
    "username" to username,
    "hasPassword" to password.isNotEmpty(),
    "scope" to scope,
    "isUsable" to isUsable,
)

internal fun settingsImageHostDraft(args: JsonObject, previous: ImageHostConfig): ImageHostConfig {
    val fields = if ("custom" in args) args.settingsObjectAt("custom") else JsonObject(emptyMap())
    val old = previous.custom
    fun field(key: String, fallback: String) = if (key in fields) fields.settingsString(key) else fallback
    return previous.copy(
        siteUrl = if ("siteUrl" in args) args.settingsString("siteUrl") else previous.siteUrl,
        token = if ("token" in args) args.settingsString("token") else previous.token,
        custom = old.copy(
            fileField = field("fileField", old.fileField),
            headerName = field("headerName", old.headerName),
            headerValue = field("headerValue", old.headerValue),
            formFields = field("formFields", old.formFields),
            urlPath = field("urlPath", old.urlPath),
            urlPrefix = field("urlPrefix", old.urlPrefix),
        ),
    )
}

internal fun ImageHostConfig.settingsJson(): JsonObject = settingsObject(
    "provider" to provider,
    "siteUrl" to siteUrl,
    "hasToken" to token.isNotEmpty(),
    "isConfigured" to isConfigured,
    "problem" to problem(),
    "custom" to settingsObject(
        "fileField" to custom.fileField,
        "headerName" to custom.headerName,
        "hasHeaderValue" to custom.headerValue.isNotEmpty(),
        "hasFormFields" to custom.formFields.isNotEmpty(),
        "urlPath" to custom.urlPath,
        "urlPrefix" to custom.urlPrefix,
    ),
)

internal fun settingsDohDraft(args: JsonObject, previous: DohConfig, capabilities: DohCapabilities): DohConfig {
    require(capabilities.canChooseRecordTypes || "includeIPv6" !in args || args.settingsBoolean("includeIPv6") == previous.includeIPv6) { "Record type selection unsupported" }
    require(capabilities.canFallBackToSystem || "fallbackToSystem" !in args || args.settingsBoolean("fallbackToSystem") == previous.fallbackToSystem) { "System DNS fallback unsupported" }
    val servers = if ("servers" !in args) {
        previous.servers
    } else {
        args.settingsArray("servers").map { element ->
            val row = element as? JsonObject ?: throw IllegalArgumentException("Invalid DNS server")
            val preset = if (row.settingsOptionalString("preset") == null) null else row.settingsEnum<DohProvider>("preset")
            val server = DohServer(
                id = row.settingsString("id"),
                preset = preset,
                customUrl = row.settingsOptionalString("customUrl").orEmpty(),
                bootstrapOverride = row.settingsOptionalString("bootstrapOverride"),
                checked = if ("checked" in row) row.settingsBoolean("checked") else false,
            )
            require(server.id.isNotBlank() && (preset == null || server.id == preset.name)) { "Invalid DNS server identity" }
            require(dohServerProblem(if (preset == null) server.customUrl else null, server.bootstrapOverride.orEmpty()) == null) { "Invalid DNS server" }
            server
        }
    }
    require(servers.map { it.id }.distinct().size == servers.size) { "Duplicate DNS servers" }
    // Preserve legacy multi-checked defaults on a switch-only edit; explicit selection must be honest.
    require(capabilities.triesServersInOrder || "servers" !in args || servers.count { it.checked } <= 1) { "Only one DNS server is supported" }
    return previous.copy(
        enabled = if ("enabled" in args) args.settingsBoolean("enabled") else previous.enabled,
        servers = servers,
        includeIPv6 = if ("includeIPv6" in args) args.settingsBoolean("includeIPv6") else previous.includeIPv6,
        fallbackToSystem = if ("fallbackToSystem" in args) args.settingsBoolean("fallbackToSystem") else previous.fallbackToSystem,
    ).also { require(it.problem() == null) { "No DNS server selected" } }
}

internal fun DohConfig.settingsJson(capabilities: DohCapabilities): JsonObject = settingsObject(
    "config" to settingsObject(
        "enabled" to enabled,
        "includeIPv6" to includeIPv6,
        "fallbackToSystem" to fallbackToSystem,
        "servers" to servers.map { settingsObject("id" to it.id, "preset" to it.preset, "customUrl" to it.customUrl, "bootstrapOverride" to it.bootstrapOverride, "checked" to it.checked, "url" to it.url, "bootstrap" to it.bootstrap) },
    ),
    "capabilities" to settingsObject("canChooseRecordTypes" to capabilities.canChooseRecordTypes, "canFallBackToSystem" to capabilities.canFallBackToSystem, "triesServersInOrder" to capabilities.triesServersInOrder),
)

internal fun UserSettings.settingsJson(showBlockedContent: Boolean): JsonObject = settingsObject(
    "themeMode" to themeMode,
    "appLanguage" to appLanguage,
    "colorSource" to colorSource,
    "presetId" to presetId,
    "seedColor" to seedColor,
    "wallpaperSeed" to wallpaperSeed,
    "wallpaperSystemPalette" to wallpaperSystemPalette,
    "wallpaperAutoUpdate" to wallpaperAutoUpdate,
    "paletteStyle" to paletteStyle,
    "savedThemes" to savedThemes.map { settingsObject("name" to it.name, "color" to it.color) },
    "fontScale" to fontScale,
    "oneHandMode" to oneHandMode,
    "einkMode" to einkMode,
    "stickerUniformSize" to stickerUniformSize,
    "stickerSize" to stickerSize,
    "imagesOnWifiOnly" to imagesOnWifiOnly,
    "reportFormat" to reportFormat,
    "feedSort" to feedSort,
    "homePageBar" to homePageBar,
    "clipboardPostPrompt" to clipboardPostPrompt,
    "holidayTheme" to holidayTheme,
    "searchHistory" to searchHistory.map { settingsObject("query" to it.query, "target" to it.target, "categorySlug" to it.categorySlug, "sort" to it.sort) },
    "recentBoards" to recentBoards,
    "hiddenHomeBoards" to hiddenHomeBoards,
    "homeBoardOrder" to homeBoardOrder,
    "disabledHomeBoards" to disabledHomeBoards,
    "postToolbarActions" to postToolbarActions,
    "replyToolbarActions" to replyToolbarActions,
    "messageToolbarActions" to messageToolbarActions,
    "notificationsEnabled" to notificationsEnabled,
    "notificationPollMinutes" to notificationPollMinutes,
    "notificationsWifiOnly" to notificationsWifiOnly,
    "notificationQuietHours" to notificationQuietHours,
    "notifyInteractions" to notifyInteractions,
    "notifyMessages" to notifyMessages,
    "notifyKeywordAlerts" to notifyKeywordAlerts,
    "notifyTrackedThreads" to notifyTrackedThreads,
    "readHistoryLimit" to readHistoryLimit,
    "updateCheckOnLaunch" to updateCheckOnLaunch,
    "updateDevChannel" to updateDevChannel,
    "onboardingSeen" to onboardingSeen,
    "oneHandTipDismissed" to oneHandTipDismissed,
    "showBlockedContent" to showBlockedContent,
)

internal fun OfflineSettings.settingsJson(): JsonObject = settingsObject("wifiOnly" to wifiOnly, "includeImages" to includeImages, "autoSyncReplies" to autoSyncReplies, "retentionDays" to retentionDays)

internal fun OfflineUsage.settingsJson(): JsonObject = settingsObject("posts" to posts, "textBytes" to textBytes, "imageBytes" to imageBytes, "freeBytes" to freeBytes, "totalBytes" to totalBytes)

internal fun OfflineState.settingsJson(postId: Long): JsonObject = when (this) {
    OfflineState.NotDownloaded -> settingsObject("postId" to postId, "state" to "NotDownloaded")
    is OfflineState.Downloading -> settingsObject("postId" to postId, "state" to "Downloading", "progress" to progress)
    is OfflineState.Downloaded -> settingsObject("postId" to postId, "state" to "Downloaded", "bytes" to bytes)
    is OfflineState.Stale -> settingsObject("postId" to postId, "state" to "Stale", "bytes" to bytes, "behindReplies" to behindReplies)
    is OfflineState.Failed -> settingsObject("postId" to postId, "state" to "Failed", "reason" to reason)
}

internal fun HostedImage.settingsJson(): JsonObject = settingsObject("id" to id, "fileName" to fileName, "url" to url, "uploadTime" to uploadTime, "sizeBytes" to sizeBytes, "mimeType" to mimeType)

internal fun StickerSubscription.settingsJson(cdn: StickerCdnSettings): JsonObject = settingsObject(
    "owner" to owner, "repo" to repo, "ref" to ref, "pinnedSha" to pinnedSha, "checkedAtMillis" to checkedAtMillis,
    "folderCount" to folderCount, "slug" to slug, "newCount" to newCount, "hasUpdate" to hasUpdate,
    "folders" to folders.map { folder ->
        settingsObject(
            "owner" to folder.owner, "repo" to folder.repo, "pinnedSha" to folder.pinnedSha,
            "path" to folder.path, "files" to folder.files, "pendingFiles" to folder.pendingFiles,
            "hidden" to folder.hidden, "name" to folder.name, "newCount" to folder.newCount,
            "key" to folderGroupKey(folder.slug, folder.path),
            "entries" to folder.files.map { path ->
                settingsObject("name" to stickerNameFromPath(path), "url" to cdn.urlFor(folder.owner, folder.repo, folder.pinnedSha, path))
            },
        )
    },
)

internal fun RepoListing.settingsJson(): JsonObject = settingsObject(
    "owner" to owner, "repo" to repo, "ref" to ref, "sha" to sha, "subPath" to subPath, "slug" to slug, "truncated" to truncated,
    "folders" to folders.map { settingsObject("path" to it.path, "files" to it.files, "totalBytes" to it.totalBytes) },
    "otherFolders" to otherFolders.map { settingsObject("path" to it.path, "files" to it.files, "totalBytes" to it.totalBytes) },
)

internal fun LinkProbe.settingsJson(): JsonObject = when (this) {
    is LinkProbe.Ok -> settingsObject("type" to "Ok", "sizeBytes" to sizeBytes)
    is LinkProbe.Broken -> settingsObject("type" to "Broken", "code" to code)
    LinkProbe.Unreachable -> settingsObject("type" to "Unreachable")
}

internal fun StickerSourceError.settingsJson(): JsonObject = when (this) {
    StickerSourceError.NotFound -> settingsObject("type" to "NotFound")
    StickerSourceError.NoImages -> settingsObject("type" to "NoImages")
    StickerSourceError.Network -> settingsObject("type" to "Network")
    StickerSourceError.Unparsable -> settingsObject("type" to "Unparsable")
    is StickerSourceError.Http -> settingsObject("type" to "Http", "code" to code)
    is StickerSourceError.RateLimited -> settingsObject("type" to "RateLimited", "resetAtEpochSeconds" to resetAtEpochSeconds)
}

internal fun settingsImageHostErrorCode(error: ImageHostError): String = when (error) {
    ImageHostError.NotConfigured -> "IMAGE_HOST_NOT_CONFIGURED"
    ImageHostError.InvalidKey -> "IMAGE_HOST_INVALID_KEY"
    ImageHostError.Cloudflare -> "IMAGE_HOST_CHALLENGE"
    ImageHostError.Network -> "NETWORK"
    ImageHostError.Unparsable -> "IMAGE_HOST_UNPARSABLE"
    ImageHostError.Unsupported -> "UNSUPPORTED"
    ImageHostError.InsecureLink -> "IMAGE_HOST_INSECURE_LINK"
    is ImageHostError.Rejected -> "IMAGE_HOST_REJECTED"
    is ImageHostError.Http -> "IMAGE_HOST_HTTP"
}

internal fun StickerUpload.settingsJson(): JsonObject = settingsObject(
    "id" to id,
    "name" to name,
    "keepOriginal" to keepOriginal,
    "progress" to progress,
    "state" to state,
    // Exception.detail can contain a credential echoed by a host. Never cross the boundary with it.
    "error" to error?.let { settingsImageHostErrorCode(it.error) },
)

internal fun TrackedThread.settingsJson(): JsonObject = settingsObject("postId" to postId, "title" to title, "lastKnownCount" to lastKnownCount, "authorName" to authorName, "categoryTitle" to categoryTitle, "categorySlug" to categorySlug)

internal fun TermsDocument.settingsJson(): JsonObject = settingsObject(
    "title" to title,
    "effectiveDate" to effectiveDate,
    "blocks" to blocks.map { block ->
        when (block) {
            is TermsBlock.Heading -> settingsObject("type" to "Heading", "level" to block.level, "text" to block.text)
            is TermsBlock.Paragraph -> settingsObject("type" to "Paragraph", "text" to block.text)
            is TermsBlock.ListBlock -> settingsObject("type" to "ListBlock", "ordered" to block.ordered, "items" to block.items)
        }
    },
)
