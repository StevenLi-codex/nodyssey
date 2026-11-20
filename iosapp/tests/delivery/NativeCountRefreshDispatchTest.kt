@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package io.github.nodyssey.ios.native

import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.net.JsonApi
import io.github.nodyssey.core.net.NodeSeekJsonClient
import io.github.nodyssey.data.NetworkMessageRepository
import io.github.nodyssey.data.NotificationCategory
import io.github.nodyssey.data.NotificationRepository
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.session.PrivateSessionBoundary
import io.github.nodyssey.data.session.SessionRepository
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.net.SessionCookieStore
import io.github.plaza.core.net.SessionCookies
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.int
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Dispatch-level regressions using the real NativeBridge and both real repositories on a JVM fixture. */
class NativeCountRefreshDispatchTest {
    @Test
    fun `held foreground count coalesces all queued message refresh intents before dispatch`() = kotlinx.coroutines.runBlocking {
        val fixture = Fixture()
        try {
            fixture.start()
            val gate = CompletableDeferred<Unit>().also { fixture.api.holdNextCount = it }
            assertTrue(fixture.request("notifications.refresh").isEmpty())
            assertEquals(1, fixture.api.countCalls)
            assertEquals(listOf<JsonElement>(JsonNull), fixture.request("messages.refresh"))
            assertEquals(listOf<JsonElement>(JsonNull), fixture.request("messages.readAll"))
            assertEquals(listOf<JsonElement>(JsonNull), fixture.request("messages.refresh"))
            assertEquals(1, fixture.api.countCalls, "no background count dispatch before foreground releases owner")
            gate.complete(Unit)
            fixture.pump()
            assertEquals(2, fixture.api.countCalls, "queued intents collapse into one post-foreground GET")
            assertEquals(0, fixture.messages.conversations().single().unreadCount)
        } finally {
            fixture.close()
        }
    }

    @Test
    fun `merged interaction publication waits behind older read and newer rows win`() = kotlinx.coroutines.runBlocking {
        val fixture = Fixture()
        try {
            fixture.start()
            val oldGate = CompletableDeferred<Unit>().also { fixture.api.holdFirstInteractionPair = it }
            val older = fixture.request("notifications.list")
            assertTrue(older.isEmpty())
            assertEquals(2, fixture.api.interactionRequestsStarted)

            val newer = fixture.request("notifications.list")
            assertTrue(newer.isEmpty(), "second one-shot merged list must queue behind the first publisher")
            assertEquals(2, fixture.api.interactionRequestsStarted, "B is queued; its repository calls have not started")
            oldGate.complete(Unit)
            fixture.pump()

            assertEquals(1, older.single().jsonArray.size)
            assertTrue(newer.single().jsonArray.isEmpty())
            assertEquals(0, fixture.counts.counts.value.overlap, "the newer merged result must remain authoritative")
            assertEquals(0, fixture.counts.counts.value.messages, "overlap serialization must preserve message counts")
        } finally {
            fixture.close()
        }
    }

    private class Fixture {
        val scheduler = TestCoroutineScheduler()
        private val main = StandardTestDispatcher(scheduler)
        val api = FixtureApi()
        val counts = NotificationRepository(api)
        val messages = NetworkMessageRepository(api) { 77L }
        private val cookies = SessionCookies(NodeSeekSite.CONFIG, object : SessionCookieStore {
            override fun cookieHeader(url: String) = NodeSeekSite.CONFIG.sessionCookieNames.first() + "=count-dispatch-fixture"
            override fun setCookie(url: String, cookie: String) = error("unexpected cookie write")
            override suspend fun removeAll() = error("unexpected cookie removal")
            override fun flush() = Unit
        })
        private val boundary = PrivateSessionBoundary(null, cookies::privateOwnerProof, emptyList(), counts::clearCounts, singleAccountLocal = true)
        private val requests = mutableListOf<NativeRequest>()

        suspend fun start() {
            Dispatchers.setMain(main)
            boundary.reconcile()
            val unusedPosts = java.lang.reflect.Proxy.newProxyInstance(PostRepository::class.java.classLoader, arrayOf(PostRepository::class.java)) { _, method, _ ->
                error("unexpected posts call ${method.name}")
            } as PostRepository
            NodysseyApp.fixture = IosAppContainer(mapOf(
                "notificationRepository" to counts,
                "messageRepository" to messages,
                "sessionRepository" to SessionRepository(cookies),
                "postRepository" to unusedPosts,
            ), boundary)
        }

        fun pump() = scheduler.runCurrent()

        fun request(operation: String, arguments: String = "{}"): MutableList<JsonElement> {
            val values = mutableListOf<JsonElement>()
            requests += NativeBridge.request(operation, arguments) { values += Json.parseToJsonElement(it).jsonObject.getValue("data") }
            pump()
            return values
        }

        fun close() {
            requests.forEach(NativeRequest::cancel)
            api.holdNextCount?.complete(Unit)
            api.holdFirstInteractionPair?.complete(Unit)
            pump()
            Dispatchers.resetMain()
        }
    }

    private class FixtureApi : JsonApi {
        var unread = true
        var holdNextCount: CompletableDeferred<Unit>? = null
        var holdFirstInteractionPair: CompletableDeferred<Unit>? = null
        var countCalls = 0
        var interactionRequestsStarted = 0

        override suspend fun getJson(path: String, referer: String): String = when (path) {
            NodeSeekJsonClient.PATH_UNREAD_COUNT -> {
                countCalls++
                val snapshot = if (unread) 1 else 0
                val hold = holdNextCount.also { holdNextCount = null }
                if (hold != null) withContext(NonCancellable) { hold.await() }
                """{"message":$snapshot,"reply":2,"atMe":2}"""
            }
            NodeSeekJsonClient.messageListPath(), NodeSeekJsonClient.messageThreadPath(22L) ->
                """{"data":[{"id":41,"sender_id":22,"receiver_id":77,"sender_name":"Fixture","content":"hello","viewed":${if (unread) 0 else 1}}]}"""
            NodeSeekJsonClient.notificationListPath(requireNotNull(NotificationCategory.REPLIES.endpoint)),
            NodeSeekJsonClient.notificationListPath(requireNotNull(NotificationCategory.MENTIONS.endpoint)) -> {
                val old = interactionRequestsStarted++ < 2
                if (old) holdFirstInteractionPair?.await()
                if (old) """{"data":[{"id":12,"comment_id":123,"viewed":false}]}""" else """{"data":[]}"""
            }
            else -> error("unexpected GET $path")
        }

        override suspend fun postJson(path: String, body: String, referer: String): String {
            if (path == NodeSeekJsonClient.PATH_MESSAGE_MARK_VIEWED_ALL || path == NodeSeekJsonClient.PATH_MESSAGE_MARK_VIEWED) unread = false
            return """{"success":true}"""
        }
    }
}
