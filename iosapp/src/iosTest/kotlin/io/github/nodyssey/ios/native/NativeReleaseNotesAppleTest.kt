package io.github.nodyssey.ios.native

import io.github.plaza.core.net.ProxyRoute
import io.github.plaza.core.net.ProxyRouteType
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

/** Real Foundation configuration tests; deliberately excluded from the Linux JVM harness. */
class NativeReleaseNotesAppleTest {
    @Test
    fun publicHistorySessionCannotReadOrWriteTheForumCookieJar() {
        val session = releaseNotesSession("test-user-agent", "en", null)
        try {
            val configuration = session.configuration
            assertNull(configuration.HTTPCookieStorage)
            assertFalse(configuration.HTTPShouldSetCookies)
            val headers = configuration.HTTPAdditionalHeaders.orEmpty()
            assertFalse(headers.keys.any { it.toString().equals("Referer", ignoreCase = true) })
            assertFalse(headers.keys.any { it.toString().equals("Cookie", ignoreCase = true) })
            assertFalse(headers.keys.any { it.toString().equals("Authorization", ignoreCase = true) })
            assertEquals("test-user-agent", headers["User-Agent"])
            assertNull(configuration.connectionProxyDictionary)
        } finally {
            session.finishTasksAndInvalidate()
        }
    }

    @Test
    fun allTrafficProxyPolicyReachesTheIsolatedSession() {
        val session = releaseNotesSession("test-user-agent", "en", ProxyRoute(ProxyRouteType.HTTP, "127.0.0.1", 1080))
        try {
            val configuration = session.configuration
            assertEquals("127.0.0.1", configuration.connectionProxyDictionary?.get("HTTPSProxy"))
            assertEquals("1080", configuration.connectionProxyDictionary?.get("HTTPSPort").toString())
            assertNull(configuration.HTTPCookieStorage)
            assertFalse(configuration.HTTPShouldSetCookies)
        } finally {
            session.finishTasksAndInvalidate()
        }
    }
}
