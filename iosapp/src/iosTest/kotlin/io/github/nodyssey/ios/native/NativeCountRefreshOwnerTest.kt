package io.github.nodyssey.ios.native

import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.net.JsonApi
import io.github.nodyssey.core.net.NodeSeekJsonClient
import io.github.nodyssey.data.NetworkMessageRepository
import io.github.nodyssey.data.NotificationRepository
import io.github.nodyssey.data.session.PrivateSessionBoundary
import io.github.nodyssey.data.session.PrivateStorePhase
import io.github.plaza.core.net.SessionCookieStore
import io.github.plaza.core.net.SessionCookies
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class NativeCountRefreshOwnerTest {
    @Test
    fun `held pre-read count drains before post-read count without blocking message data`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val api = CountApi()
        val counts = NotificationRepository(api)
        val messages = NetworkMessageRepository(api) { 77L }
        val old = api.holdNext()
        try {
            owner.request { counts.refreshCounts() }
            old.entered.await()
            messages.markAllRead()
            owner.request { counts.refreshCounts() }
            assertEquals(0, messages.conversations().single().unreadCount)
            assertTrue(messages.thread(22L).unreadIds.isEmpty())
            assertEquals(1, api.countCalls, "post-read count must not overtake held pre-read count")
            old.release.complete(Unit)
            job.children.toList().forEach { it.join() }
            assertEquals(2, api.countCalls)
            assertEquals(0, counts.counts.value.messages, "late pre-read response must not restore unread")
        } finally {
            job.cancelAndJoin()
        }
    }

    @Test
    fun `new intent during follow-up is retained and earlier pending intents coalesce`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val a = CompletableDeferred<Unit>()
        val enteredA = CompletableDeferred<Unit>()
        val b = CompletableDeferred<Unit>()
        val enteredB = CompletableDeferred<Unit>()
        val seen = mutableListOf<String>()
        try {
            owner.request {
                seen += "A"
                enteredA.complete(Unit)
                a.await()
            }
            enteredA.await()
            owner.request { seen += "obsolete" }
            owner.request {
                seen += "B"
                enteredB.complete(Unit)
                b.await()
            }
            a.complete(Unit)
            enteredB.await()
            owner.request { seen += "C" }
            b.complete(Unit)
            job.children.toList().forEach { it.join() }
            assertEquals(listOf("A", "B", "C"), seen)
        } finally {
            job.cancelAndJoin()
        }
    }

    @Test
    fun `failed refresh does not cancel owner and retains newer refresh intent`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val release = CompletableDeferred<Unit>()
        var recovered = false
        val entered = CompletableDeferred<Unit>()
        try {
            owner.request {
                entered.complete(Unit)
                release.await()
                error("offline")
            }
            entered.await()
            owner.request { recovered = true }
            release.complete(Unit)
            job.children.toList().forEach { it.join() }
            assertTrue(job.isActive)
            assertTrue(recovered)
            owner.request { recovered = false }
            job.children.toList().forEach { it.join() }
            assertFalse(recovered, "failure must not latch the worker busy")
        } finally {
            job.cancelAndJoin()
        }
    }

    @Test
    fun `foreground count publishers serialize and cancelling a waiter preserves background work`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val held = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        var secondRan = false
        var followupRan = false
        try {
            owner.request {
                entered.complete(Unit)
                held.await()
            }
            entered.await()
            val waiter = async(start = CoroutineStart.UNDISPATCHED) { owner.run { secondRan = true } }
            assertFalse(waiter.isCompleted)
            waiter.cancelAndJoin()
            owner.request { followupRan = true }
            held.complete(Unit)
            job.children.toList().forEach { it.join() }
            assertFalse(secondRan)
            assertTrue(followupRan)
            owner.run { secondRan = true }
            assertTrue(secondRan, "cancelled waiter must not latch the publication mutex")
        } finally {
            job.cancelAndJoin()
        }
    }

    @Test
    fun `owner cancellation waits for uncooperative drain without running pending work`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val held = CompletableDeferred<Unit>()
        var pendingRan = false
        val entered = CompletableDeferred<Unit>()
        owner.request {
            entered.complete(Unit)
            withContext(NonCancellable) { held.await() }
            currentCoroutineContext().ensureActive()
        }
        entered.await()
        owner.request { pendingRan = true }
        job.cancel()
        assertFalse(job.isCompleted, "cancellation must not acknowledge an undrained refresh")
        held.complete(Unit)
        withTimeout(2000) { job.join() }
        assertFalse(pendingRan)
    }

    @Test
    fun `identity replacement drains late I O discards old intent and accepts new count`() = runBlocking {
        val job = SupervisorJob()
        val owner = NativeCountRefreshOwner(CoroutineScope(job + Dispatchers.Unconfined))
        val api = CountApi()
        val counts = NotificationRepository(api)
        val cookies = object : SessionCookieStore {
            var account = "fixture-A"
            override fun cookieHeader(url: String) = NodeSeekSite.CONFIG.sessionCookieNames.first() + "=" + account
            override fun setCookie(url: String, cookie: String) = Unit
            override suspend fun removeAll() = Unit
            override fun flush() = Unit
        }
        val session = SessionCookies(NodeSeekSite.CONFIG, cookies)
        val boundary = PrivateSessionBoundary(
            provenance = null,
            owner = session::privateOwnerProof,
            participants = emptyList(),
            beforePublication = counts::clearCounts,
            singleAccountLocal = true,
        )
        boundary.reconcile()
        val oldEpoch = boundary.state.value.identityEpoch
        fun request(epoch: String) = owner.request {
            boundary.protect {
                if (boundary.state.value.identityEpoch == epoch) counts.refreshCounts()
            }
        }
        val old = api.holdNext()
        try {
            api.countOverride = 7
            request(oldEpoch)
            old.entered.await()
            request(oldEpoch)
            val change = async(start = CoroutineStart.UNDISPATCHED) {
                boundary.sessionMutation { cookies.account = "fixture-B" }
            }
            assertEquals(PrivateStorePhase.TRANSITIONING, boundary.state.value.phase)
            assertFalse(change.isCompleted, "new identity must wait for old I O drain")
            old.release.complete(Unit)
            withTimeout(2000) { change.await() }
            job.children.toList().forEach { it.join() }
            assertNotEquals(oldEpoch, boundary.state.value.identityEpoch)
            assertEquals(0, counts.counts.value.messages)
            assertEquals(1, api.countCalls, "queued old epoch must not dispatch a count")
            api.countOverride = 2
            request(boundary.state.value.identityEpoch)
            job.children.toList().forEach { it.join() }
            assertEquals(2, api.countCalls)
            assertEquals(2, counts.counts.value.messages)
        } finally {
            old.release.complete(Unit)
            job.cancelAndJoin()
        }
    }

    private class Held {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
    }

    private class CountApi : JsonApi {
        var unread = true
        var countCalls = 0
        var countOverride: Int? = null
        private var held: Held? = null
        fun holdNext(): Held = Held().also { held = it }
        override suspend fun getJson(path: String, referer: String): String {
            if (path == NodeSeekJsonClient.PATH_UNREAD_COUNT) {
                countCalls++
                val snapshot = countOverride ?: if (unread) 1 else 0
                val gate = held.also { held = null }
                gate?.entered?.complete(Unit)
                // Match iOS joinOnCancellation: late callback drains, then cancellation is checked
                // before repository publication. No coroutine-test dependency or timing sleeps.
                if (gate != null) withContext(NonCancellable) { gate.release.await() }
                currentCoroutineContext().ensureActive()
                return """{"message":$snapshot}"""
            }
            check(path == NodeSeekJsonClient.messageListPath() || path == NodeSeekJsonClient.messageThreadPath(22L))
            return """{"data":[{"id":41,"sender_id":22,"receiver_id":77,"sender_name":"Fixture","content":"hello","viewed":${if (unread) 0 else 1}}]}"""
        }
        override suspend fun postJson(path: String, body: String, referer: String): String {
            check(path == NodeSeekJsonClient.PATH_MESSAGE_MARK_VIEWED_ALL)
            unread = false
            return """{"success":true}"""
        }
    }
}
