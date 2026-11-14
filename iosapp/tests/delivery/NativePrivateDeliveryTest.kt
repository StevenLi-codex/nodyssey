@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package io.github.nodyssey.ios.native

import androidx.paging.PagingData
import io.github.nodyssey.data.FeedPost
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlin.coroutines.coroutineContext
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.session.*
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.net.*
import java.lang.reflect.Proxy
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import okio.Path.Companion.toPath
import org.junit.Test
import kotlin.test.*

/** Used only by --interval's explicitly instrumented scratch bridge. */
internal object DeliveryProbe { var beforePublish: (suspend () -> Unit)? = null }

class NativePrivateDeliveryTest {
    private class Jar : SessionCookieStore {
        var header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=delivery-a"
        override fun cookieHeader(url: String) = header
        override fun setCookie(url: String, cookie: String) { error("No transport allowed") }
        override suspend fun removeAll() { header = "" }
        override fun flush() = Unit
    }

    private class Fixture(memoryJournal: Boolean = false) {
        val main = StandardTestDispatcher()
        val storeJob = SupervisorJob()
        val file = File(System.getProperty("java.io.tmpdir"), "delivery-${UUID.randomUUID()}.preferences_pb")
        val jar = Jar()
        val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
        var cleaned = false
        val boundary = PrivateSessionBoundary(
            PrivateStoreProvenance(if (memoryJournal) object : androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences> {
                private val value = kotlinx.coroutines.flow.MutableStateFlow(androidx.datastore.preferences.core.emptyPreferences())
                override val data: kotlinx.coroutines.flow.Flow<androidx.datastore.preferences.core.Preferences> = value
                override suspend fun updateData(transform: suspend (androidx.datastore.preferences.core.Preferences) -> androidx.datastore.preferences.core.Preferences): androidx.datastore.preferences.core.Preferences {
                    value.value = transform(value.value)
                    return value.value
                }
            } else PreferenceDataStoreFactory.createWithPath(
                scope = CoroutineScope(storeJob + Dispatchers.IO), produceFile = { file.path.toPath() },
            ), setOf("controlled")),
            session::privateOwnerProof,
            listOf(PrivateStoreParticipant("controlled", { true }, { cleaned = true })),
        )
        val requests = mutableListOf<NativeRequest>()
        val controlScope = CoroutineScope(SupervisorJob() + main)
        var transition: Job? = null
        var beforeIndex: () -> Unit = {}
        var search: Flow<List<FeedPost>> = flowOf(emptyList())
        var feed: Flow<PagingData<FeedPost>> = flowOf(PagingData.from(emptyList()))
        var totals: Flow<Int> = flowOf(1)
        val posts = Proxy.newProxyInstance(PostRepository::class.java.classLoader, arrayOf(PostRepository::class.java)) { _, method, _ ->
            when (method.name) {
                "feedRowIndexOfPage" -> { beforeIndex(); 37 }
                "search" -> search
                "feed" -> feed
                "feedTotalPages" -> totals
                else -> error("Unexpected repository method ${method.name}")
            }
        } as PostRepository
        suspend fun open() {
            Dispatchers.setMain(main)
            boundary.reconcile()
            NodysseyApp.fixture = IosAppContainer(mapOf("sessionRepository" to session, "postRepository" to posts), boundary)
        }
        fun resetNow() {
            val epoch = boundary.state.value.identityEpoch
            transition = controlScope.launch(start = CoroutineStart.UNDISPATCHED) { boundary.reset(true, epoch) }
        }
        suspend fun pumpUntil(condition: () -> Boolean) {
            withTimeout(3000) { while (!condition()) { main.scheduler.runCurrent(); delay(1) } }
        }
        suspend fun finish() {
            DeliveryProbe.beforePublish = null
            requests.forEach { it.cancel() }
            controlScope.cancel()
            pumpUntil { requests.all { request -> requestJob(request).isCompleted } && transition?.isCompleted != false }
            storeJob.cancelAndJoin()
            file.delete()
            Dispatchers.resetMain()
        }
    }
    private companion object {
        fun requestJob(request: NativeRequest): Job = NativeRequest::class.java.getDeclaredField("job").run {
            isAccessible = true; get(request) as Job
        }
    }

    @Test fun callbackRetainsLeaseUntilReturn() = runBlocking {
        val f = Fixture(memoryJournal = true)
        try {
            f.open()
            var callbackReturned = false
            var transitionPassedCallback = false
            val replies = mutableListOf<String>()
            f.requests += NativeBridge.request("feed.pageIndex", "{}") {
                replies += it
                f.resetNow()
                transitionPassedCallback = f.cleaned
                callbackReturned = true
            }
            f.pumpUntil { callbackReturned && f.transition?.isCompleted == true }
            assertEquals(1, replies.size)
            assertTrue(replies.single().contains("\"index\":37"))
            assertFalse(transitionPassedCallback, "Private cleanup crossed a live result callback: lease ended before publication")
            assertTrue(f.cleaned)
        } finally { f.finish() }
    }

    @Test fun ownerChangeDuringDispatchSuppressesResult() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            f.beforeIndex = { f.jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=delivery-b" }
            val replies = mutableListOf<String>()
            val request = NativeBridge.request("feed.pageIndex", "{}", replies::add)
            f.requests += request
            f.pumpUntil { requestJob(request).isCompleted }
            assertEquals(1, replies.size)
            assertTrue(replies.single().contains("PRIVATE_STORE_RECOVERY_REQUIRED"))
            assertFalse(replies.single().contains("\"index\":37"))
        } finally { f.finish() }
    }

    @Test fun cancelledObserverDrainsBeforeTransitionAndCanRestart() = observerLifetime(cancelFirst = true)
    @Test fun transitionRevokesObserverAndExplicitRestartReadsAgain() = observerLifetime(cancelFirst = false)

    private fun observerLifetime(cancelFirst: Boolean) = runBlocking {
        val f = Fixture()
        val entered = CompletableDeferred<Unit>()
        val draining = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var lateWrites = 0
        var collections = 0
        f.search = flow {
            collections++
            try { emit(emptyList()); entered.complete(Unit); awaitCancellation() }
            finally { withContext(NonCancellable) { draining.complete(Unit); release.await(); lateWrites++ } }
        }
        try {
            f.open()
            val oldReplies = mutableListOf<String>()
            val old = NativeBridge.observe("search.local", "{\"query\":\"local\"}", oldReplies::add)
            f.requests += old
            f.pumpUntil { entered.isCompleted && oldReplies.any { it.contains("\"data\":[]") } }
            val drained = CompletableDeferred<Unit>()
            old.invokeOnCompletion { drained.complete(Unit) }
            if (cancelFirst) old.cancel()
            f.resetNow()
            f.pumpUntil { draining.isCompleted }
            assertFalse(f.cleaned, "Cleanup must join a revoked observer's non-cancellable writer")
            assertFalse(drained.isCompleted)
            assertEquals(0, lateWrites)
            val deliveriesBeforeDrain = oldReplies.size
            // Explicit UI cancellation closes resubscription ownership while reset is pending.
            old.cancel()
            release.complete(Unit)
            f.pumpUntil { drained.isCompleted && f.transition?.isCompleted == true }
            assertEquals(1, lateWrites)
            assertTrue(f.cleaned)
            assertEquals(deliveriesBeforeDrain, oldReplies.size, "Cancelled observer published after revocation")
            val newReplies = mutableListOf<String>()
            val restarted = NativeBridge.observe("search.local", "{\"query\":\"local\"}", newReplies::add)
            f.requests += restarted
            f.pumpUntil { newReplies.any { it.contains("\"data\":[]") } }
            assertEquals(2, collections)
            assertTrue(newReplies.first().contains("\"data\":null"), "Restart must clear stale UI before rows")
            restarted.cancel()
            f.pumpUntil { requestJob(restarted).isCompleted }
            assertEquals(2, lateWrites)
        } finally { release.complete(Unit); f.finish() }
    }

    @Test fun pagingTransitionJoinsDataThenTotalsChild() = pagingLifetime(dataFirst = true)
    @Test fun pagingTransitionJoinsTotalsChildThenData() = pagingLifetime(dataFirst = false)

    private fun pagingLifetime(dataFirst: Boolean) = runBlocking {
        val f = Fixture()
        val dataEntered = CompletableDeferred<Unit>()
        val totalsEntered = CompletableDeferred<Unit>()
        val dataDraining = CompletableDeferred<Unit>()
        val totalsDraining = CompletableDeferred<Unit>()
        val releaseData = CompletableDeferred<Unit>()
        val releaseTotals = CompletableDeferred<Unit>()
        var lateData = false
        var lateTotals = false
        f.feed = flow {
            try { emit(PagingData.from(emptyList())); dataEntered.complete(Unit); awaitCancellation() }
            finally { withContext(NonCancellable) { dataDraining.complete(Unit); releaseData.await(); lateData = true } }
        }
        f.totals = flow {
            try { emit(1); totalsEntered.complete(Unit); awaitCancellation() }
            finally { withContext(NonCancellable) { totalsDraining.complete(Unit); releaseTotals.await(); lateTotals = true } }
        }
        try {
            f.open()
            val replies = mutableListOf<String>()
            val request = NativeBridge.observe("feed", "{\"pagerId\":\"owned\"}", replies::add)
            f.requests += request
            f.pumpUntil { dataEntered.isCompleted && totalsEntered.isCompleted && replies.any { it.contains("\"pagerId\":\"owned\"") } }
            val drained = CompletableDeferred<Unit>()
            request.invokeOnCompletion { drained.complete(Unit) }
            f.resetNow()
            f.pumpUntil { dataDraining.isCompleted && totalsDraining.isCompleted }
            request.cancel()
            assertFalse(f.cleaned)
            assertFalse(drained.isCompleted)
            val deliveriesAtRevocation = replies.size
            if (dataFirst) releaseData.complete(Unit) else releaseTotals.complete(Unit)
            f.pumpUntil { if (dataFirst) lateData else lateTotals }
            assertFalse(f.cleaned, "Cleanup ran before both Paging data and launched totals child drained")
            assertFalse(drained.isCompleted, "NativeRequest drain ignored a structured Paging child")
            if (dataFirst) releaseTotals.complete(Unit) else releaseData.complete(Unit)
            f.pumpUntil { drained.isCompleted && f.transition?.isCompleted == true }
            assertTrue(lateData && lateTotals && f.cleaned)
            assertEquals(deliveriesAtRevocation, replies.size)
            val closedReplies = mutableListOf<String>()
            val closed = NativeBridge.request("paging.refresh", "{\"pagerId\":\"owned\"}", closedReplies::add)
            f.requests += closed
            f.pumpUntil { requestJob(closed).isCompleted }
            assertTrue(closedReplies.single().contains("PAGER_CLOSED"), "Presenter handle outlived observation")
            // Same ID can be reused only by a new observation, with actual Paging presenter code.
            f.feed = flowOf(PagingData.from(emptyList()))
            f.totals = flowOf(2)
            val nextReplies = mutableListOf<String>()
            val next = NativeBridge.observe("feed", "{\"pagerId\":\"owned\"}", nextReplies::add)
            f.requests += next
            f.pumpUntil { nextReplies.any { it.contains("\"totalPages\":2") } }
            assertFalse(requestJob(next).isCompleted, "Static PagingData must not end the observation")
            next.cancel()
            f.pumpUntil { requestJob(next).isCompleted }
        } finally { releaseData.complete(Unit); releaseTotals.complete(Unit); f.finish() }
    }

    @Test fun transitionInDispatchToCallbackIntervalSuppressesOldData() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            val replies = mutableListOf<String>()
            var intervalReached = false
            DeliveryProbe.beforePublish = {
                DeliveryProbe.beforePublish = null
                intervalReached = true
                f.resetNow()
                // The old outer request survives reset; a live lease is cancelled instead.
                f.transition!!.join()
            }
            val request = NativeBridge.request("feed.pageIndex", "{}", replies::add)
            f.requests += request
            f.pumpUntil { requestJob(request).isCompleted && f.transition?.isCompleted == true }
            assertTrue(intervalReached, "Run this case with --interval")
            assertFalse(replies.any { it.contains("\"index\":37") }, "Old private result published after transition started")
            assertTrue(f.cleaned)
        } finally { f.finish() }
    }
}
