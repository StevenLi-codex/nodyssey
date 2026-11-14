package io.github.nodyssey.ios.native

import io.github.nodyssey.data.session.SessionState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class NativeBridgeTest {
    @Test
    fun `failure never exports exception message or cause`() {
        val result = nativeFailure(IllegalStateException("cookie=secret-token", Exception("password")))
        assertFalse(result.contains("secret-token"))
        assertFalse(result.contains("password"))
        assertEquals("INTERNAL", Json.parseToJsonElement(result).jsonObject["error"]!!.jsonObject["code"]!!.jsonPrimitive.content)
    }

    @Test
    fun `cancellation is not converted to an error envelope`() {
        assertFailsWith<CancellationException> { nativeFailure(CancellationException("cancel")) }
    }

    @Test
    fun `canceled request cannot emit late success`() {
        val job = Job()
        var calls = 0
        val request = NativeRequest(job)
        request.cancel()
        request.cancel()
        assertFailsWith<CancellationException> { nativeDeliver(job, JsonPrimitive("late")) { calls++ } }
        assertEquals(0, calls)
    }

    @Test
    fun `logout rejects a result even if opaque fingerprint collides`() {
        val before = SessionState(isSignedIn = true, fingerprint = 31)
        val failure = assertFailsWith<NativeFailure> {
            nativeCheckSession(before, before.copy(isSignedIn = false))
        }
        assertEquals("SESSION_CHANGED", failure.code)
    }

    @Test
    fun `account change rejects old result without relying on generation`() {
        val before = SessionState(isSignedIn = true, fingerprint = 31, generation = 8)
        val failure = assertFailsWith<NativeFailure> {
            nativeCheckSession(before, before.copy(fingerprint = 32))
        }
        assertEquals("SESSION_CHANGED", failure.code)
        nativeCheckSession(before, before.copy(generation = 9))
    }

    @Test
    fun `argument validation rejects lossy integer and wrong boolean`() {
        val args = Json.parseToJsonElement("""{"postId":1.5,"collected":"false"}""").jsonObject
        assertFailsWith<NativeFailure> { args.nativeLong("postId") }
        assertFailsWith<NativeFailure> { args.nativeBoolean("collected") }
    }
}
