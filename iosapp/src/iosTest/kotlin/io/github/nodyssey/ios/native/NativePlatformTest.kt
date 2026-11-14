package io.github.nodyssey.ios.native

import io.github.nodyssey.data.session.SessionState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativePlatformTest {
    @Test
    fun `closing during seed never starts observer and publishes only after drain`() = runBlocking {
        val seeded = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val lifecycle = NativeCookieLifecycle(
            seed = {
                events += "seed"
                seeded.await()
            },
            start = { events += "start" },
            stop = { events += "stop" },
            drain = { events += "drain" },
            publish = { events += "publish" },
        )
        // Undispatched starts establish both suspension points before releasing seed;
        // no timing/sleep or undeclared kotlinx-coroutines-test dependency is required.
        val opening = launch(start = CoroutineStart.UNDISPATCHED) { assertFalse(lifecycle.open()) }
        val closing = launch(start = CoroutineStart.UNDISPATCHED) { lifecycle.close() }
        seeded.complete(Unit)
        opening.join()
        closing.join()
        lifecycle.close()
        assertEquals(listOf("seed", "stop", "drain", "publish"), events)
    }

    @Test
    fun `old clearance never completes a new challenge`() {
        val baseline = SessionState(hasClearance = true, fingerprint = 7)
        assertFalse(nativeBrowserGoalReached("challenge", baseline, baseline))
        assertTrue(nativeBrowserGoalReached("challenge", baseline, baseline.copy(fingerprint = 8)))
        assertFalse(nativeBrowserGoalReached("login", baseline, baseline.copy(fingerprint = 8)))
        assertTrue(nativeBrowserGoalReached("login", baseline, baseline.copy(isSignedIn = true, fingerprint = 8)))
    }

    @Test
    fun `wifi preference defers automatic network but explicit load overrides it`() {
        assertTrue(nativeDeferImage(wifiOnly = true, onWifi = false, allowMetered = false))
        assertFalse(nativeDeferImage(wifiOnly = true, onWifi = true, allowMetered = false))
        assertFalse(nativeDeferImage(wifiOnly = true, onWifi = false, allowMetered = true))
        assertFalse(nativeDeferImage(wifiOnly = false, onWifi = false, allowMetered = false))
    }

    @Test
    fun `turnstile blank tokens and unknown events fail closed`() {
        assertEquals("token", nativeTurnstileMessageKind("token", "opaque-value"))
        assertEquals("unavailable", nativeTurnstileMessageKind("token", " \n"))
        assertEquals("expired", nativeTurnstileMessageKind("expired", ""))
        assertEquals("unavailable", nativeTurnstileMessageKind("error", "never export provider detail"))
        assertEquals("unavailable", nativeTurnstileMessageKind("unknown", "opaque-value"))
    }

    @Test
    fun `image URL admission refuses credentials schemes and parser ambiguity`() {
        assertTrue(nativeImageUrlAllowed("https://cdn.example/image.png"))
        listOf(
            "file:///private/image.png",
            "javascript:alert(1)",
            "data:image/png;base64,AA==",
            "https://user:secret@cdn.example/a",
            "https://good.example\\@evil.example/a",
            "https://cdn.example/%zz",
            "//cdn.example/a",
            " https://cdn.example/a",
        ).forEach { assertFalse(nativeImageUrlAllowed(it), it) }
    }
}
