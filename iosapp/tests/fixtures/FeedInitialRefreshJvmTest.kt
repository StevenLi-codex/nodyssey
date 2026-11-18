@file:OptIn(androidx.paging.ExperimentalPagingApi::class)
package io.github.nodyssey.ios.native

import androidx.paging.*
import androidx.room.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.github.nodyssey.data.*
import io.github.nodyssey.data.local.*
import io.github.nodyssey.model.*
import io.github.plaza.core.AppClock
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

/** Real initialize/Pager/load/Room chain; fixture remote is the only source of fresh rows. */
fun main(args: Array<String>) = runBlocking {
    val db = Room.databaseBuilder<NodeSeekDatabase>(args[0]).setDriver(BundledSQLiteDriver()).build()
    val requests = mutableListOf<Triple<String?, Int, FeedSort>>()
    var version = 1L
    var fail = false
    var empty = false
    var titleSuffix = ""
    var blocked = false
    var gate: CompletableDeferred<Unit>? = null
    val reveal = MutableStateFlow(false)
    val clock = object : AppClock { override fun nowMillis() = 100_000L }
    val remote = object : PostRemoteDataSource {
        override suspend fun loadList(categorySlug: String?, page: Int, sort: FeedSort): PostListPage {
            requests += Triple(categorySlug, page, sort)
            gate?.await()
            if (fail) error("offline fixture")
            return PostListPage(if (empty) emptyList() else listOf(PostSummary(version, "version $version$titleSuffix", "fixture", null, null, null, categorySlug, null, 0, null, null, isBlocked = blocked)), page, false)
        }
        override suspend fun loadSearch(query: String, page: Int, categorySlug: String?, sort: FeedSort): PostListPage = error("unused")
        override suspend fun loadDetail(postId: Long, page: Int): PostDetail = error("unused")
    }
    val repository = OfflineFirstPostRepository(db, remote, clock, showBlockedContent = reveal)
    val context = NativeContext(Graph(repository))
    val state = PagingState<Int, FeedPostRow>(emptyList(), null, PagingConfig(30), 0)
    fun mediator(force: Boolean = false) = FeedRemoteMediator("tech|postTime", db, clock, forceInitialRefresh = force) { page -> remote.loadList("tech", page, FeedSort.POST_TIME) }
    suspend fun observe(force: Boolean, expected: Long, expectedRequests: Int, toggleReveal: Boolean = false, expectError: Boolean = false) {
        val snapshots = mutableListOf<JsonElement>()
        val job = launch {
            context.fixtureObserve("feed", buildJsonObject {
                put("pagerId", "test-$force-$expected"); put("categorySlug", "tech")
                put("sort", "POST_TIME"); put("page", 1); put("forceInitialRefresh", force)
            })!!.collect {
                snapshots += it
                if (force && !expectError && it.jsonObject["remoteRefreshComplete"]?.jsonPrimitive?.boolean == true) {
                    val expectedItems = JsonArray(if (empty || (blocked && !reveal.value)) emptyList() else listOf(JsonPrimitive(expected)))
                    check(it.jsonObject["items"]!!.jsonArray == expectedItems) {
                        "Completion published cached rows instead of fresh rows: $it"
                    }
                    check(empty || fixtureRenderedTitles[expected] == "version $expected$titleSuffix") {
                        "Completion preceded successful Room transaction"
                    }
                }
                if (expectError) check(it.jsonObject["remoteRefreshComplete"]?.jsonPrimitive?.boolean != true)
                if (force) println("SNAP force=$force expected=$expected gate=${gate?.isCompleted} $it")
                if (force && gate?.isCompleted == false) {
                    check(it.jsonObject["remoteRefreshComplete"]?.jsonPrimitive?.boolean != true) {
                        "Remote refresh reported complete before held mediator network response"
                    }
                }
            }
        }
        try {
            withTimeout(5000) {
                while (snapshots.none { s ->
                    val o = s.jsonObject
                    o["items"]!!.jsonArray == JsonArray(if (empty || (blocked && !reveal.value)) emptyList() else listOf(JsonPrimitive(expected))) &&
                        o["refresh"]!!.jsonObject["status"]!!.jsonPrimitive.content == (if (expectError) "Error" else "NotLoading") &&
                        (!force || expectError || o["remoteRefreshComplete"]?.jsonPrimitive?.boolean == true)
                }) delay(10)
            }
            if (toggleReveal) {
                val before = snapshots.size
                reveal.value = !reveal.value
                withTimeout(5000) { while (snapshots.size == before) delay(10) }
            }
            delay(100)
            check(requests.size == expectedRequests) { "Expected $expectedRequests requests, got $requests" }
        } finally { job.cancelAndJoin() }
    }
    try {
        check(mediator().load(LoadType.REFRESH, state) is RemoteMediator.MediatorResult.Success)
        check(db.feedDao().firstLoadedPage("tech|postTime") == 1)
        check(mediator().initialize() == RemoteMediator.InitializeAction.SKIP_INITIAL_REFRESH)
        observe(false, 1, 1)
        println("PASS ordinary fresh page-one observation makes zero network requests")
        version = 2
        check(mediator(true).initialize() == RemoteMediator.InitializeAction.LAUNCH_INITIAL_REFRESH)
        check(requests.size == 1) { "initialize must not itself fetch" }
        // The reader can be on page N inside a cached window that still begins at one.
        // Explicit return-to-top must not be swallowed by this same fresh timestamp.
        gate = CompletableDeferred()
        val explicit = async { observe(true, 2, 2, toggleReveal = true) }
        withTimeout(1500) { while (requests.size < 2) delay(10) }
        delay(200) // Let the cached Room source finish while mediator network is held.
        check(db.feedDao().firstLoadedPage("tech|postTime") == 1)
        check(db.feedDao().commentCount(1) == 0) { "Cache removed before network succeeded" }
        reveal.value = !reveal.value
        delay(200) // Exercise a replacement source while the unique remote response is still held.
        check(requests.size == 2)
        gate.complete(Unit)
        explicit.await()
        gate = null
        check(requests.last() == Triple("tech", 1, FeedSort.POST_TIME))
        println("PASS explicit page-one refresh bypasses fresh TTL, preserves board/sort, requests once")
        println("PASS reveal-setting pager rebuild consumes no additional force refresh")
        observe(false, 2, 2)
        println("PASS subsequent ordinary appearance retains fresh cache without a second request")
        fail = true
        observe(true, 2, 3, expectError = true)
        println("PASS explicit network failure reports Error while cached rows remain readable")
        fail = false
        version = 3
        observe(true, 3, 4)
        println("PASS immediate explicit refresh also requests exactly once and publishes fresh terminal")
        titleSuffix = " changed"
        observe(true, 3, 5)
        println("PASS unchanged IDs with changed content require the committed Room generation")
        observe(true, 3, 6)
        println("PASS identical content still completes after a fresh Room presentation")
        empty = true
        observe(true, 3, 7, toggleReveal = true)
        observe(true, 3, 8)
        println("PASS nonempty-to-empty and empty-to-empty refresh complete without ID heuristics")
        empty = false
        version = 4
        check(FeedRemoteMediator("tech|postTime", db, clock, startPage = 9) { page ->
            remote.loadList("tech", page, FeedSort.POST_TIME)
        }.load(LoadType.REFRESH, state) is RemoteMediator.MediatorResult.Success)
        check(db.feedDao().firstLoadedPage("tech|postTime") == 9)
        version = 5
        observe(true, 5, 10)
        check(requests.last() == Triple("tech", 1, FeedSort.POST_TIME))
        println("PASS explicit page-N to page-one replacement issues exactly one board/sort request")
        blocked = true
        version = 6
        reveal.value = false
        val localSnapshots = mutableListOf<JsonObject>()
        val local = launch {
            context.fixtureObserve("feed", buildJsonObject {
                put("pagerId", "blocked"); put("categorySlug", "tech"); put("sort", "POST_TIME")
                put("page", 1); put("forceInitialRefresh", true)
            })!!.collect { localSnapshots += it.jsonObject }
        }
        suspend fun awaitVisible(ids: List<Long>) = withTimeout(5000) {
            val expected = JsonArray(ids.map(::JsonPrimitive))
            while (localSnapshots.lastOrNull()?.let {
                it["items"] == expected && it["remoteRefreshComplete"]?.jsonPrimitive?.boolean == true
            } != true) delay(10)
        }
        try {
            awaitVisible(emptyList())
            reveal.value = true
            awaitVisible(listOf(6))
            reveal.value = false
            awaitVisible(emptyList())
            check(requests.size == 11)
        } finally { local.cancelAndJoin() }
        println("PASS SQL-blocked rows reveal/hide on same pager with no repeat remote request")
        for (force in listOf(false, true)) {
            val anchorDb = Room.databaseBuilder<NodeSeekDatabase>(args[0] + "-anchor-$force").setDriver(BundledSQLiteDriver()).build()
            val anchorReveal = MutableStateFlow(false)
            var anchorRequests = 0
            val anchorRemote = object : PostRemoteDataSource {
                override suspend fun loadList(categorySlug: String?, page: Int, sort: FeedSort): PostListPage {
                    anchorRequests++
                    return PostListPage((1L..120L).map {
                        PostSummary(it, "post $it", "fixture", null, null, null, categorySlug, null, 0, null, null)
                    }, page, false)
                }
                override suspend fun loadSearch(query: String, page: Int, categorySlug: String?, sort: FeedSort): PostListPage = error("unused")
                override suspend fun loadDetail(postId: Long, page: Int): PostDetail = error("unused")
            }
            val anchorRepository = OfflineFirstPostRepository(anchorDb, anchorRemote, clock, showBlockedContent = anchorReveal)
            val anchorSessions = NativePagingSessions()
            val anchorSnapshots = mutableListOf<JsonObject>()
            check(FeedRemoteMediator("tech|postTime", anchorDb, clock) { page ->
                anchorRemote.loadList("tech", page, FeedSort.POST_TIME)
            }.load(LoadType.REFRESH, state) is RemoteMediator.MediatorResult.Success)
            val anchorJob = launch {
                nativePagingFlow("anchor", anchorRepository.feed("tech", FeedSort.POST_TIME, 1, force), null, 1,
                    anchorSessions, kotlin.coroutines.EmptyCoroutineContext).collect { anchorSnapshots += it.jsonObject }
            }
            suspend fun awaitAnchor(condition: () -> Boolean) = withTimeout(5000) {
                while (!condition()) yield()
            }
            try {
                awaitAnchor {
                    anchorSnapshots.lastOrNull()?.let {
                        it["itemCount"]!!.jsonPrimitive.int == 120 &&
                            it["refresh"]!!.jsonObject["status"]!!.jsonPrimitive.content == "NotLoading" &&
                            (!force || it["remoteRefreshComplete"]?.jsonPrimitive?.boolean == true)
                    } == true
                }
                val presenter = anchorSessions.get("anchor")
                presenter[75]
                awaitAnchor { presenter.peek(75)?.summary?.postId == 76L }
                // Ordinary reveal intentionally rebuilds its Pager; only the explicit handle retains it.
                for (readMark in if (force) listOf(true, false) else listOf(true)) {
                    presenter[75]
                    var refreshed = false
                    val pagesUpdated: () -> Unit = { refreshed = true }
                    presenter.addOnPagesUpdatedListener(pagesUpdated)
                    try {
                        if (readMark) anchorDb.readMarkDao().upsert(ReadMarkEntity(76L, 100_001L, 0))
                        else anchorReveal.value = true
                        awaitAnchor { refreshed }
                        check(presenter.peek(75)?.summary?.postId == 76L) {
                            "Loaded anchor 76 became a placeholder after ${if (readMark) "read mark" else "reveal"}; force=$force"
                        }
                        if (readMark) check(presenter.peek(75)?.isRead == true)
                        check(presenter.snapshot().size == 120)
                        check(anchorRequests == if (force) 2 else 1) { "Local invalidation repeated remote I/O" }
                    } finally { presenter.removeOnPagesUpdatedListener(pagesUpdated) }
                }
            } finally { anchorJob.cancelAndJoin(); anchorDb.close() }
        }
        println("PASS 120-row read-mark ordinary/explicit and explicit reveal invalidations preserve loaded anchor 76 without extra I/O")
    } finally { db.close() }
}
