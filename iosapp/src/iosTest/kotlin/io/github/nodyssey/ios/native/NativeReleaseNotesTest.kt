package io.github.nodyssey.ios.native

import io.github.nodyssey.data.proxy.ProxyConfig
import io.github.nodyssey.data.proxy.ProxyScope
import io.github.nodyssey.data.proxy.ProxyType
import io.github.plaza.core.net.HttpRequest
import io.github.plaza.core.net.HttpResponse
import io.github.plaza.core.net.HttpTransport
import io.github.plaza.core.net.SiteError
import io.github.plaza.core.net.SiteException
import io.github.plaza.core.net.UploadProgress
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativeReleaseNotesTest {
    private val fixture = Json.parseToJsonElement(publishedReleaseNotesFixture).jsonObject
    private val rows = fixture.getValue("versions").jsonArray

    private fun manifest(entries: List<JsonObject>): String = JsonObject(fixture + ("versions" to JsonArray(entries))).toString()

    private fun changed(vararg fields: Pair<String, Any?>): String =
        manifest(listOf(JsonObject(rows.first().jsonObject + settingsObject(*fields))))

    private fun unreadable(body: String) {
        assertEquals(
            "RELEASE_NOTES_UNREADABLE",
            assertFailsWith<NativeFailure> {
                parseReleaseNotes(body, true)
                Unit
            }.code,
        )
    }

    @Test
    fun publishedFixturePreservesAuthorTextAndUsesSemanticOrder() {
        val parsed = parseReleaseNotes(publishedReleaseNotesFixture, false)
        assertEquals(listOf("1.2.22", "1.2.10", "1.2.9"), parsed.map { it.versionName })
        assertEquals("2026-10-09", parsed.first().publishedOn)
        assertEquals(rows[1].jsonObject.getValue("notes").jsonPrimitive.content.trim(), parsed.first().notes)
        val snapshot = releaseNotesSnapshot(parsed, false)
        val entry = snapshot.getValue("releases").jsonArray.first().jsonObject
        assertTrue(entry.getValue("notes").jsonPrimitive.content.startsWith("### 新增"))
        assertTrue(entry.getValue("text").jsonPrimitive.content.startsWith("新增"))
        assertEquals("https://github.com/5151561/nodyssey/releases/tag/v1.2.22", entry.getValue("htmlUrl").jsonPrimitive.content)
        assertFalse(snapshot.toString().contains("downloadUrl"))
    }

    @Test
    fun malformedAndOversizedDocumentsAreNotEmptyHistory() {
        listOf(
            "",
            "<html>private error</html>",
            "[]",
            "{}",
            "{\"schema\":2,\"versions\":[]}",
            "{\"schema\":\"1\",\"versions\":[]}",
            "{\"schema\":1,\"versions\":null}",
        ).forEach(::unreadable)
        unreadable(" ".repeat(1_048_577) + publishedReleaseNotesFixture)
        unreadable(manifest(List(1001) { rows.first().jsonObject }))
        unreadable(changed("notes" to "界".repeat(32_769)))
        unreadable(changed("versionName" to ""))
        unreadable(changed("versionName" to "x".repeat(129)))
        unreadable(changed("tag" to "x".repeat(161)))
        unreadable(changed("publishedOn" to "not-a-date"))
        unreadable(changed("preRelease" to "false"))
        unreadable(manifest(listOf(rows.first().jsonObject, rows.first().jsonObject)))
    }

    @Test
    fun untrustedReleaseLinksNeverReachNativeLinkActions() {
        listOf(
            "http://github.com/5151561/nodyssey/releases/tag/v1.2.9",
            "https://github.com.evil.test/5151561/nodyssey/releases/tag/v1.2.9",
            "https://github.com/other/project/releases/tag/v1.2.9",
            "https://github.com/5151561/nodyssey/releases/tag/../../issues",
            "https://github.com/5151561/nodyssey/releases/tag/v1.2.9?token=secret",
            "javascript:alert(1)",
        ).forEach { unreadable(changed("releaseUrl" to it)) }
    }

    @Test
    fun stableFilterAndPreReleaseOrderingDoNotClaimUpdateAvailability() {
        fun dev(version: String) = JsonObject(
            rows.first().jsonObject + settingsObject(
                "versionName" to version,
                "tag" to "v$version",
                "preRelease" to true,
                "releaseUrl" to "https://github.com/5151561/nodyssey/releases/tag/v$version",
            ),
        )
        val body = manifest(listOf(dev("1.2.22-dev.9"), rows[1].jsonObject, dev("1.2.22-dev.10")))
        assertEquals(listOf("1.2.22"), parseReleaseNotes(body, false).map { it.versionName })
        assertEquals(listOf("1.2.22", "1.2.22-dev.10", "1.2.22-dev.9"), parseReleaseNotes(body, true).map { it.versionName })
        unreadable(manifest(listOf(JsonObject(dev("1.2.22-dev.10") + ("preRelease" to JsonPrimitive(false))))))
        assertEquals(emptyList(), parseReleaseNotes(manifest(emptyList()), false))
        val compatible = JsonObject(fixture + ("futureField" to JsonPrimitive("ignored"))).toString()
        assertEquals(3, parseReleaseNotes(compatible, false).size)
        assertEquals("v1.2.9", parseReleaseNotes(changed("tag" to ""), false).single().tag)
        assertEquals("", parseReleaseNotes(changed("releaseUrl" to "", "publishedOn" to "", "notes" to ""), false).single().notes)
    }

    @Test
    fun requestIsOnlyPublicHistoryAndFailuresAreNotSuccessfulEmptyLists() = runBlocking {
        var recorded: HttpRequest? = null
        var response = HttpResponse(200, RELEASE_NOTES_URL, emptyMap(), publishedReleaseNotesFixture)
        var failure: Exception? = null
        val http = object : HttpTransport {
            override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse {
                recorded = request
                failure?.let { throw it }
                return response
            }
        }
        val result = fetchReleaseNotes(http, false)
        assertEquals(3, result.getValue("releases").jsonArray.size)
        assertEquals(HttpRequest(RELEASE_NOTES_URL, "GET", mapOf("Accept" to "application/json")), recorded)
        for ((status, code) in listOf(429 to "RATE_LIMITED", 404 to "RELEASE_NOTES_HTTP", 503 to "RELEASE_NOTES_HTTP")) {
            response = response.copy(code = status, body = "private error details")
            assertEquals(code, assertFailsWith<NativeFailure> { fetchReleaseNotes(http, false) }.code)
        }
        response = response.copy(code = 200, url = "https://unexpected.invalid/changelog.json")
        assertEquals("RELEASE_NOTES_SOURCE", assertFailsWith<NativeFailure> { fetchReleaseNotes(http, false) }.code)
        response = response.copy(url = RELEASE_NOTES_URL)
        assertEquals("RELEASE_NOTES_UNREADABLE", assertFailsWith<NativeFailure> { fetchReleaseNotes(http, false) }.code)
        failure = SiteException(SiteError.Network, detail = "private error details")
        assertEquals("NETWORK", assertFailsWith<NativeFailure> { fetchReleaseNotes(http, false) }.code)
        failure = CancellationException("cancelled")
        assertFailsWith<CancellationException> { fetchReleaseNotes(http, false) }
        Unit
    }

    @Test
    fun proxyScopeUsesSharedPolicyWithoutSendingForumCredentials() {
        val configured = ProxyConfig(enabled = true, type = ProxyType.SOCKS, host = "127.0.0.1", port = 1080, username = "proxy-user", password = "proxy-password")
        assertNull(releaseNotesProxyRoute(configured.copy(scope = ProxyScope.FORUM_ONLY)))
        assertNull(releaseNotesProxyRoute(configured.copy(enabled = false)))
        assertNull(releaseNotesProxyRoute(configured.copy(host = "")))
        val route = releaseNotesProxyRoute(configured)!!
        assertEquals("SOCKS", route.type.name)
        assertEquals(configured.host, route.host)
        assertEquals(configured.port, route.port)
        assertEquals(configured.username, route.username)
        assertEquals(configured.password, route.password)
        assertEquals("HTTP", releaseNotesProxyRoute(configured.copy(type = ProxyType.HTTP))!!.type.name)
    }
}
