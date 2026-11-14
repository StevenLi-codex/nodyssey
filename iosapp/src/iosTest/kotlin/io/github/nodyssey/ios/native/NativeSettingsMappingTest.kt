package io.github.nodyssey.ios.native

import io.github.nodyssey.data.dns.DohCapabilities
import io.github.nodyssey.data.dns.DohConfig
import io.github.nodyssey.data.imagehost.CustomHostFields
import io.github.nodyssey.data.imagehost.ImageHostConfig
import io.github.nodyssey.data.imagehost.ImageHostError
import io.github.nodyssey.data.imagehost.ImageHostProvider
import io.github.nodyssey.data.proxy.ProxyConfig
import io.github.nodyssey.data.sticker.StickerCdn
import io.github.nodyssey.data.sticker.StickerCdnSettings
import io.github.nodyssey.data.sticker.StickerSubscription
import io.github.nodyssey.data.sticker.SubscribedFolder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeSettingsMappingTest {
    @Test
    fun omittedProxySecretIsPreservedButExplicitEmptyClears() {
        val stored = ProxyConfig(password = "private-proxy-secret")
        assertEquals(stored.password, settingsProxyDraft(Json.parseToJsonElement("{\"host\":\"new.host\"}").jsonObject, stored).password)
        assertEquals("", settingsProxyDraft(Json.parseToJsonElement("{\"password\":\"\"}").jsonObject, stored).password)
        assertFalse(stored.settingsJson().toString().contains(stored.password))
    }

    @Test
    fun allCustomHostCredentialLocationsAreRedactedAndPreserved() {
        val stored = ImageHostConfig(ImageHostProvider.CUSTOM, "https://image.invalid", "token-secret", CustomHostFields(headerValue = "header-secret", formFields = "key=form-secret"))
        val wire = stored.settingsJson().toString()
        listOf("token-secret", "header-secret", "form-secret").forEach { assertFalse(wire.contains(it)) }
        val draft = settingsImageHostDraft(Json.parseToJsonElement("{\"custom\":{\"urlPath\":\"data.url\"}}").jsonObject, stored)
        assertEquals(stored.custom.headerValue, draft.custom.headerValue)
        assertEquals(stored.custom.formFields, draft.custom.formFields)
        assertEquals("data.url", draft.custom.urlPath)
    }

    @Test
    fun nativeDohRefusesIgnoredControlsAndMultipleActiveServers() {
        val caps = DohCapabilities(false, false, false)
        assertFailsWith<IllegalArgumentException> {
            settingsDohDraft(Json.parseToJsonElement("{\"includeIPv6\":false}").jsonObject, DohConfig(), caps)
        }
        assertFailsWith<IllegalArgumentException> {
            settingsDohDraft(Json.parseToJsonElement("{\"servers\":[{\"id\":\"ALIDNS\",\"preset\":\"ALIDNS\",\"checked\":true},{\"id\":\"GOOGLE\",\"preset\":\"GOOGLE\",\"checked\":true}]}").jsonObject, DohConfig(), caps)
        }
    }

    @Test
    fun subscribedPreviewUsesSavedCdnPinnedCommitAndEncodedPath() {
        val folder = SubscribedFolder("owner", "pack", "commit123", "faces", listOf("faces/a b.png"), null, false)
        val subscription = StickerSubscription("owner", "pack", "main", "commit123", 0, listOf(folder))
        val row = subscription.settingsJson(StickerCdnSettings(StickerCdn.CUSTOM, "https://cdn.invalid/gh/"))
        val entry = row.settingsArray("folders").first().jsonObject.settingsArray("entries").first().jsonObject
        assertEquals("https://cdn.invalid/gh/owner/pack@commit123/faces/a%20b.png", entry.settingsString("url"))
    }

    @Test
    fun siteStickerCatalogueKeepsShortcodeSeparateFromImageUrl() {
        val groups = settingsSiteGroups()
        val ac = groups.first { it.settingsString("key") == "site:ac" }
        val sticker = ac.settingsArray("entries").first().jsonObject
        assertEquals(" :ac01: ", sticker.settingsString("shortcode"))
        assertTrue(sticker.settingsString("url").endsWith("/static/image/sticker/ac/01.png"))
        val fluent = groups.first { it.settingsString("key") == "fluent" }
        assertEquals("Unicode", fluent.settingsArray("entries").first().jsonObject.settingsString("type"))
    }

    @Test
    fun imageHostFailuresRetainRecoveryWithoutServerDetails() {
        assertEquals("IMAGE_HOST_INVALID_KEY", settingsImageHostErrorCode(ImageHostError.InvalidKey))
        assertEquals("IMAGE_HOST_CHALLENGE", settingsImageHostErrorCode(ImageHostError.Cloudflare))
        assertEquals("IMAGE_HOST_REJECTED", settingsImageHostErrorCode(ImageHostError.Rejected(413)))
        assertEquals("UNSUPPORTED", settingsImageHostErrorCode(ImageHostError.Unsupported))
    }

    @Test
    fun remoteSourcesCannotBeQueuedAsUserPickedImages() {
        assertFailsWith<IllegalArgumentException> {
            settingsPickedImages(Json.parseToJsonElement("{\"images\":[{\"source\":\"https://remote.invalid/a.jpg\",\"name\":\"a.jpg\"}]}").jsonObject)
        }
        val images = settingsPickedImages(Json.parseToJsonElement("{\"images\":[{\"source\":\"file:///private/picked.jpg\",\"name\":\"picked.jpg\"}]}").jsonObject)
        assertEquals("file:///private/picked.jpg", images.single().source)
    }

    @Test
    fun malformedBooleanAndEnumNeverBecomeDefaultsOrLeakInput() {
        val error = assertFailsWith<IllegalArgumentException> {
            settingsProxyDraft(Json.parseToJsonElement("{\"type\":\"credential-do-not-echo\"}").jsonObject, ProxyConfig())
        }
        assertFalse(error.message.orEmpty().contains("credential-do-not-echo"))
        assertFailsWith<IllegalArgumentException> {
            settingsProxyDraft(Json.parseToJsonElement("{\"enabled\":\"false\"}").jsonObject, ProxyConfig())
        }
        assertTrue(settingsProxyDraft(Json.parseToJsonElement("{\"enabled\":true,\"host\":\"localhost\",\"port\":8080}").jsonObject, ProxyConfig()).enabled)
    }
}
