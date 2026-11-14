package io.github.nodyssey.ios.native

import io.github.nodyssey.data.proxy.ProxyClientKind
import io.github.nodyssey.data.proxy.ProxyConfig
import io.github.nodyssey.data.proxy.ProxyType
import io.github.nodyssey.data.proxy.routes
import io.github.plaza.core.net.HttpRequest
import io.github.plaza.core.net.HttpTransport
import io.github.plaza.core.net.NSUrlSessionTransport
import io.github.plaza.core.net.ProxyRoute
import io.github.plaza.core.net.ProxyRouteType
import io.github.plaza.core.net.SiteException
import io.github.plaza.core.net.appleUrlSession
import io.github.plaza.core.net.deviceAcceptLanguage
import io.github.plaza.core.update.ReleaseNote
import io.github.plaza.core.update.compareVersionNames
import io.github.plaza.core.update.isPreReleaseVersionName
import io.github.plaza.core.update.releaseNotesText
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

// Same source as Android's NodysseyRelease.UPDATES_BASE_URL; no update/install API is used.
internal const val RELEASE_NOTES_URL = "https://5151561.github.io/nodyssey/changelog.json"
private val RELEASE_VERSION = Regex("""[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?""")
private val RELEASE_TAG = Regex("""[0-9A-Za-z][0-9A-Za-z.+-]*""")
private val RELEASE_DATE = Regex("""[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])""")

internal suspend fun NativeContext.releaseNotesRequest(args: JsonObject): JsonObject {
    val includePreRelease = if ("includePreRelease" in args) args.settingsBoolean("includePreRelease") else false
    // Per-request snapshot of the existing third-party proxy policy. Never use the forum transport:
    // that one carries the WebView cookie jar, Referer, and signed forum request wrapper.
    val session = releaseNotesSession(graph.userAgent.value, deviceAcceptLanguage(), releaseNotesProxyRoute(graph.proxySettings.config.first()))
    try {
        return withContext(graph.dispatchers.default) {
            fetchReleaseNotes(NSUrlSessionTransport { session }, includePreRelease)
        }
    } finally {
        session.finishTasksAndInvalidate()
    }
}

internal fun releaseNotesSession(userAgent: String, acceptLanguage: String, proxy: ProxyRoute?) = appleUrlSession(
    userAgent = userAgent,
    acceptLanguage = acceptLanguage,
    referer = null,
    cookies = null,
    proxy = proxy,
)

internal fun releaseNotesProxyRoute(config: ProxyConfig): ProxyRoute? =
    if (!config.routes(ProxyClientKind.THIRD_PARTY)) {
        null
    } else {
        ProxyRoute(
            type = if (config.type == ProxyType.HTTP) ProxyRouteType.HTTP else ProxyRouteType.SOCKS,
            host = config.host,
            port = config.port,
            username = config.username,
            password = config.password,
        )
    }

internal suspend fun fetchReleaseNotes(http: HttpTransport, includePreRelease: Boolean): JsonObject {
    val response = try {
        http.execute(HttpRequest(url = RELEASE_NOTES_URL, method = "GET", headers = mapOf("Accept" to "application/json")))
    } catch (_: SiteException) {
        // NSURLSession's transport uses SiteException for connection failures only. No detail escapes.
        throw NativeFailure("NETWORK")
    }
    if (response.url != RELEASE_NOTES_URL) throw NativeFailure("RELEASE_NOTES_SOURCE")
    if (response.code == 429) throw NativeFailure("RATE_LIMITED")
    if (!response.isSuccessful) throw NativeFailure("RELEASE_NOTES_HTTP")
    return releaseNotesSnapshot(parseReleaseNotes(response.body, includePreRelease), includePreRelease)
}

internal fun parseReleaseNotes(body: String, includePreRelease: Boolean): List<ReleaseNote> =
    try {
        // HttpTransport returns a complete decoded body; these are parser/output bounds, not a
        // streaming download cap. Do not claim otherwise (see swiftui-release-notes.md).
        require(body.length <= 1_048_576 && body.encodeToByteArray().size <= 1_048_576)
        val root = Json.parseToJsonElement(body) as? JsonObject ?: throw IllegalArgumentException()
        require(root.settingsInt("schema") == 1)
        val versions = root.settingsArray("versions")
        require(versions.size <= 1000)
        val seen = mutableSetOf<String>()
        versions.map { value ->
            val row = value as? JsonObject ?: throw IllegalArgumentException()
            val version = row.settingsString("versionName")
            require(version.length <= 128 && RELEASE_VERSION.matches(version) && seen.add(version))
            val tag = row.settingsString("tag").ifBlank { "v$version" }
            require(tag.length <= 160 && RELEASE_TAG.matches(tag))
            val notes = row.settingsString("notes")
            require(notes.length <= 32_768)
            val date = row.settingsString("publishedOn")
            require(date.isEmpty() || RELEASE_DATE.matches(date))
            val url = row.settingsString("releaseUrl")
            require(url.isEmpty() || url == "https://github.com/5151561/nodyssey/releases/tag/$tag")
            val preRelease = row.settingsBoolean("preRelease")
            require(preRelease == isPreReleaseVersionName(version))
            ReleaseNote(
                versionName = version,
                tag = tag,
                notes = notes.trim(),
                publishedOn = date,
                preRelease = preRelease,
                htmlUrl = url,
            )
        }.filter { includePreRelease || !it.preRelease }
            .sortedWith { left, right -> compareVersionNames(right.versionName, left.versionName) }
    } catch (_: IllegalArgumentException) {
        throw NativeFailure("RELEASE_NOTES_UNREADABLE")
    }

internal fun releaseNotesSnapshot(notes: List<ReleaseNote>, includePreRelease: Boolean): JsonObject = settingsObject(
    "sourceUrl" to RELEASE_NOTES_URL,
    "includesPreRelease" to includePreRelease,
    "releases" to notes.map {
        settingsObject(
            "versionName" to it.versionName,
            "tag" to it.tag,
            "publishedOn" to it.publishedOn,
            "preRelease" to it.preRelease,
            "notes" to it.notes,
            "text" to releaseNotesText(it.notes),
            "htmlUrl" to it.htmlUrl,
        )
    },
)
