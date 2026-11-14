package io.github.nodyssey.ios.native

import io.github.nodyssey.data.emptyLoadedPagingData
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

class NativeContentTest {
    @Test
    fun `concurrent identical mutation is rejected and cancellation releases gate`() = runBlocking {
        val gate = NativeMutationGate()
        val started = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var writes = 0
        val first = async {
            gate.run("publish") {
                writes++
                started.complete(Unit)
                release.await()
            }
        }
        started.await()
        assertFailsWith<NativeFailure> { gate.run("publish") { writes++ } }
        first.cancel()
        first.join()
        gate.run("publish") { writes++ }
        assertEquals(2, writes)
    }

    @Test
    fun `empty pager stops loading and canceling collector releases presenter`() = runBlocking {
        val sessions = NativePagingSessions()
        val result = nativePagingFlow(
            "empty",
            flowOf(emptyLoadedPagingData()),
            null,
            1,
            sessions,
            Dispatchers.Unconfined,
        ).first { it.jsonObject["refresh"]?.jsonObject?.get("status")?.jsonPrimitive?.content == "NotLoading" }
        assertEquals(0, result.jsonObject["itemCount"]!!.jsonPrimitive.int)
        assertEquals(JsonArray(emptyList()), result.jsonObject["items"])
        assertFalse(sessions.contains("empty"))
    }
}
