@file:OptIn(androidx.paging.ExperimentalPagingApi::class)
package io.github.nodyssey.ios.native

import androidx.paging.*
import androidx.room.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.github.nodyssey.data.*
import io.github.nodyssey.data.local.*
import io.github.nodyssey.data.session.PrivateOwnerProof
import io.github.nodyssey.data.session.PrivatePostRepository
import io.github.nodyssey.data.session.PrivateSessionBoundary
import io.github.nodyssey.model.*
import io.github.plaza.core.AppClock
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

/** Remote is controlled; dispatcher branch, presenter, mediator, repository and Room are real. */
fun main(args: Array<String>) = runBlocking {
    val receipts = args.getOrNull(1) == "receipts" || args.getOrNull(1) == "receipt-minimal"
    var tokenSequence = 0
    var sequence = 0
    var stage = "seed"
    fun trace(kind: String, vararg values: Pair<String, JsonElement>) {
        println("TRACE " + buildJsonObject {
            put("sequence", ++sequence); put("stage", stage); put("kind", kind)
            values.forEach { (key, value) -> put(key, value) }
        })
    }
    fun text(s: String?) = s?.let(::JsonPrimitive) ?: JsonNull
    fun rows(id: Long, title: String = "post $id") = JsonArray(listOf(buildJsonObject { put("id", id); put("title", title) }))
    data class Reply(val id: Long, val title: String = "post $id", val gate: CompletableDeferred<Unit>? = null, val fail: Boolean = false, val empty: Boolean = false)
    data class Call(val number: Int, val slug: String?, val page: Int, val sort: FeedSort, val reply: Reply, var returned: Boolean = false, var cancelled: Boolean = false)
    data class Pull(val pager: String, val expected: JsonArray, val baseline: JsonArray, val fail: Boolean, val callStart: Int, val token: String,
                    var loading: Boolean = false, var terminal: JsonObject? = null)
    val db = Room.databaseBuilder<NodeSeekDatabase>(args[0]).setDriver(BundledSQLiteDriver()).build()
    var now = 100_000L
    val clock = object : AppClock { override fun nowMillis() = now }
    var reply = Reply(1)
    val calls = mutableListOf<Call>()
    val reveal = MutableStateFlow(false)
    val problems = mutableListOf<String>()
    var pull: Pull? = null
    val snapshots = mutableMapOf<String, MutableList<JsonObject>>()
    val jobs = mutableMapOf<String, Job>()
    fun verify(ok: Boolean, message: String) {
        trace(if (ok) "assert_pass" else "assert_fail", "message" to text(message))
        if (!ok) problems += message
    }
    suspend fun until(message: String, condition: () -> Boolean) {
        try { withTimeout(8_000) { while (!condition()) delay(2) } }
        catch (e: TimeoutCancellationException) { error("TIMEOUT: $message; problems=$problems") }
    }
    val remote = object : PostRemoteDataSource {
        override suspend fun loadList(categorySlug: String?, page: Int, sort: FeedSort): PostListPage {
            val call = Call(calls.size + 1, categorySlug, page, sort, reply)
            calls += call
            trace("remote_enter", "call" to JsonPrimitive(call.number), "categorySlug" to text(categorySlug), "page" to JsonPrimitive(page), "sort" to text(sort.name), "held" to JsonPrimitive(call.reply.gate != null))
            try {
                call.reply.gate?.await()
                if (call.reply.fail) {
                    trace("remote_error", "call" to JsonPrimitive(call.number))
                    error("offline fixture")
                }
                call.returned = true
                now += 1_000
                trace("remote_return", "call" to JsonPrimitive(call.number), "clock" to JsonPrimitive(now))
                val posts = if (call.reply.empty) emptyList() else listOf(PostSummary(call.reply.id, call.reply.title, "fixture", null, null, null, categorySlug, null, 0, null, null))
                return PostListPage(posts, page, false)
            } catch (e: CancellationException) {
                call.cancelled = true
                trace("remote_cancel", "call" to JsonPrimitive(call.number))
                throw e
            }
        }
        override suspend fun loadSearch(query: String, page: Int, categorySlug: String?, sort: FeedSort): PostListPage = error("unused")
        override suspend fun loadDetail(postId: Long, page: Int): PostDetail = error("unused")
    }
    val repository = OfflineFirstPostRepository(db, remote, clock, showBlockedContent = reveal)
    var owner = PrivateOwnerProof("fixture-owner-a")
    val boundary = if (receipts) PrivateSessionBoundary(null, { owner }, emptyList(), singleAccountLocal = true) else null
    boundary?.reconcile()
    val context = NativeContext(Graph(if (boundary == null) repository else PrivatePostRepository(repository, boundary)))
    val state = PagingState<Int, FeedPostRow>(emptyList(), null, PagingConfig(30), 0)
    suspend fun seed(slug: String?, sort: FeedSort, id: Long) {
        reply = Reply(id)
        check(FeedRemoteMediator(feedKeyFor(slug, sort), db, clock) { remote.loadList(slug, it, sort) }.load(LoadType.REFRESH, state) is RemoteMediator.MediatorResult.Success)
        check(FeedRemoteMediator(feedKeyFor(slug, sort), db, clock) { remote.loadList(slug, it, sort) }.initialize() == RemoteMediator.InitializeAction.SKIP_INITIAL_REFRESH)
    }
    fun status(snapshot: JsonObject) = snapshot["refresh"]!!.jsonObject["status"]!!.jsonPrimitive.content
    suspend fun open(id: String, slug: String?, sort: FeedSort, expected: JsonArray) {
        val before = calls.size
        val arguments = buildJsonObject { put("pagerId", id); put("categorySlug", text(slug)); put("sort", sort.name); put("page", 1) }
        trace("observe", "operation" to text("feed"), "arguments" to arguments)
        snapshots[id] = mutableListOf()
        jobs[id] = launch {
            context.fixtureObserve("feed", arguments)!!.collect { value ->
                val snapshot = value.jsonObject
                snapshots.getValue(id) += snapshot
                trace("snapshot", "snapshot" to snapshot)
                val flight = pull
                if (flight != null && flight.pager == id) {
                    when (status(snapshot)) {
                        "Loading" -> flight.loading = true
                        "NotLoading", "Error" -> if (flight.terminal == null &&
                            (if (receipts) snapshot["refreshFailure"]?.jsonPrimitive?.contentOrNull == flight.token || snapshot["refreshReceipt"]?.jsonPrimitive?.contentOrNull == flight.token else flight.loading)) {
                            flight.terminal = snapshot
                            trace("first_store_style_terminal", "snapshot" to snapshot)
                            val call = calls.drop(flight.callStart).firstOrNull()
                            if (!flight.fail) {
                                verify(call?.returned == true, "terminal for $id follows real remote return")
                                verify(snapshot["items"] == flight.expected, "first Loading->NotLoading for $id contains expected Room rows")
                            } else {
                                verify(status(snapshot) == "Error", "failed refresh terminal is Error")
                                verify(snapshot["items"] == flight.baseline, "failed refresh retains cached rows")
                            }
                        }
                    }
                }
            }
        }
        until("cached ordinary $id fully settled") {
            snapshots.getValue(id).lastOrNull()?.let {
                it["items"] == expected && status(it) == "NotLoading" &&
                    it["append"]!!.jsonObject["status"]!!.jsonPrimitive.content == "NotLoading" &&
                    it["prepend"]!!.jsonObject["status"]!!.jsonPrimitive.content == "NotLoading"
            } == true
        }
        verify(fixtureContains(id), "presenter registered for $id")
        verify(calls.size == before, "ordinary fresh $id initializes with cache and no remote call")
        trace("registered", "pagerId" to text(id), "presenterIdentity" to JsonPrimitive(System.identityHashCode(fixturePresenter(id))))
        fixturePresenter(id).addLoadStateListener { states ->
            trace("synchronous_load_states", "pagerId" to text(id), "sourceRefresh" to text(states.source.refresh.toString()),
                "mediatorRefresh" to text(states.mediator?.refresh.toString()), "combinedRefresh" to text(states.refresh.toString()))
        }
        fixturePresenter(id).addOnPagesUpdatedListener {
            trace("pages_updated", "pagerId" to text(id), "rows" to nativeContentArray(fixturePresenter(id).snapshot().items, ::nativeContentJson))
        }
    }
    suspend fun close(id: String) {
        jobs.remove(id)!!.cancelAndJoin()
        verify(!fixtureContains(id), "presenter unregistered after cancelling $id")
        trace("closed", "pagerId" to text(id))
    }
    suspend fun command(id: String, token: String) {
        val arguments = buildJsonObject { put("pagerId", id); if (receipts) put("refreshToken", token) }
        trace("command", "operation" to text("paging.refresh"), "arguments" to arguments,
            "presenterIdentity" to JsonPrimitive(System.identityHashCode(fixturePresenter(id))), "remoteCountBefore" to JsonPrimitive(calls.size))
        val ack = context.fixtureRequest("paging.refresh", arguments)
        trace("command_ack", "pagerId" to text(id), "ack" to (ack ?: JsonNull), "remoteCountAtAck" to JsonPrimitive(calls.size))
        verify(ack == JsonNull, "paging.refresh $id ACK is JsonNull, not completion")
    }
    suspend fun startPull(id: String, next: Reply, slug: String?, sort: FeedSort): Pull {
        val baseline = snapshots.getValue(id).last()["items"]!!.jsonArray
        val expected = if (next.empty) JsonArray(emptyList()) else rows(next.id, next.title)
        val flight = Pull(id, expected, baseline, next.fail, calls.size, "refresh-${++tokenSequence}")
        reply = next
        pull = flight
        val presenter = fixturePresenter(id)
        command(id, flight.token)
        until("real remote for $id") { calls.size > flight.callStart }
        val call = calls[flight.callStart]
        verify(Triple(call.slug, call.page, call.sort) == Triple(slug, 1, sort), "remote arguments for $id match board/sort/page")
        verify(fixturePresenter(id) === presenter, "refresh reuses the exact registered presenter $id")
        if (next.gate != null) {
            until("Loading while held $id") { flight.loading }
            // Drain the event loop while remote is held: no time-derived completion inference.
            repeat(50) { yield() }
            verify(flight.terminal == null, "ACK is not terminal while $id remote is held")
            verify(snapshots.getValue(id).last()["items"] == baseline, "cached rows remain while $id remote is held")
            verify(calls.size == flight.callStart + 1, "one remote request during held $id pull")
            if (receipts) {
                val before = snapshots.getValue(id).size
                reveal.value = !reveal.value
                db.readMarkDao().upsert(ReadMarkEntity(baseline.firstOrNull()?.jsonObject?.get("id")?.jsonPrimitive?.long ?: next.id, now, 0))
                until("local Room generation while $id held") { snapshots.getValue(id).size > before }
                repeat(50) { yield() }
                verify(!call.cancelled && !call.returned && calls.size == flight.callStart + 1,
                    "held remote survives local reveal/readmark without another fetch")
                verify(flight.terminal == null, "pre-commit local generation cannot supply this command receipt")
                try {
                    context.fixtureRequest("paging.refresh", buildJsonObject { put("pagerId", id); put("refreshToken", "new-intention-${flight.token}") })
                    verify(false, "new distinct intention while held must explicitly refuse instead of cancelling remote")
                } catch (e: NativeFailure) {
                    verify(e.code == "BUSY", "new distinct intention while held is BUSY, not successful ACK")
                }
                verify(!call.cancelled && calls.size == flight.callStart + 1 && flight.terminal == null,
                    "refused new token cannot cancel, relabel or complete held old token")
            }
        }
        return flight
    }
    suspend fun finishPull(flight: Pull, slug: String?, sort: FeedSort, release: Boolean = true) {
        val call = calls[flight.callStart]
        if (release) call.reply.gate?.complete(Unit)
        until("terminal after actual refresh ${flight.pager}") { flight.terminal != null }
        if (!flight.fail) {
            until("Room-backed fresh rows ${flight.pager}") { snapshots.getValue(flight.pager).lastOrNull()?.let { status(it) == "NotLoading" && it["items"] == flight.expected } == true }
            val key = db.feedDao().remoteKey(feedKeyFor(slug, sort))!!
            trace("room_readback", "feedKey" to text(feedKeyFor(slug, sort)), "refreshedAtMillis" to JsonPrimitive(key.refreshedAtMillis), "clock" to JsonPrimitive(now), "snapshot" to snapshots.getValue(flight.pager).last())
            verify(key.refreshedAtMillis == now, "successful refresh committed new Room remote key for ${flight.pager}")
        }
        repeat(100) { yield() }
        verify(calls.size == flight.callStart + 1, "exactly one remote request for ${flight.pager} pull")
        pull = null
    }
    try {
        if (args.getOrNull(1) == "minimal" || args.getOrNull(1) == "receipt-minimal") {
            stage = "minimal-ordinary-retained"
            seed("daily", FeedSort.POST_TIME, 10)
            open("daily-minimal", "daily", FeedSort.POST_TIME, rows(10))
            finishPull(startPull("daily-minimal", Reply(11, gate = CompletableDeferred()), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
            close("daily-minimal")
            trace("summary", "seedCalls" to JsonPrimitive(1), "actualRemoteCalls" to JsonPrimitive(calls.size), "problems" to JsonArray(problems.map(::JsonPrimitive)))
            check(problems.isEmpty()) { "BEHAVIORAL RED: ${problems.joinToString("; ")}" }
            return@runBlocking
        }
        seed(null, FeedSort.LAST_REPLY, 1)
        seed("daily", FeedSort.POST_TIME, 10)
        seed("another", FeedSort.LAST_REPLY, 20)
        val seeded = calls.size
        stage = "all-retained"
        open("all-1", null, FeedSort.LAST_REPLY, rows(1))
        finishPull(startPull("all-1", Reply(2, gate = CompletableDeferred()), null, FeedSort.LAST_REPLY), null, FeedSort.LAST_REPLY)
        close("all-1")
        stage = "daily-first-retained"
        open("daily-1", "daily", FeedSort.POST_TIME, rows(10))
        finishPull(startPull("daily-1", Reply(11, gate = CompletableDeferred()), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        // A second actual command on this SAME ordinary pager, not forceInitialRefresh.
        stage = "daily-same-pager-identical"
        finishPull(startPull("daily-1", Reply(11, gate = CompletableDeferred()), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-held-old-refresh"
        val old = startPull("daily-1", Reply(999, gate = CompletableDeferred()), "daily", FeedSort.POST_TIME)
        val oldCall = calls[old.callStart]
        pull = null
        if (boundary != null) {
            val epoch = boundary.state.value.identityEpoch
            owner = PrivateOwnerProof("fixture-owner-b")
            boundary.reconcile()
            verify(epoch != boundary.state.value.identityEpoch, "private boundary revokes old owner while its remote is held")
        }
        close("daily-1")
        verify(oldCall.cancelled && !oldCall.returned, "held old daily refresh is cancelled without returning/committing")
        val oldSnapshotCount = snapshots.getValue("daily-1").size
        stage = "another-retained"
        open("another-1", "another", FeedSort.LAST_REPLY, rows(20))
        finishPull(startPull("another-1", Reply(21, gate = CompletableDeferred()), "another", FeedSort.LAST_REPLY), "another", FeedSort.LAST_REPLY)
        close("another-1")
        stage = "daily-return-new-pull"
        open("daily-2", "daily", FeedSort.POST_TIME, rows(11))
        try {
            context.fixtureRequest("paging.refresh", buildJsonObject { put("pagerId", "daily-1") })
            verify(false, "stale old pager command must fail")
        } catch (e: NativeFailure) {
            trace("stale_command_rejected", "code" to text(e.code), "pagerId" to text("daily-1"))
            verify(e.code == "PAGER_CLOSED", "stale old pager command rejected as PAGER_CLOSED")
        }
        val current = startPull("daily-2", Reply(12, gate = CompletableDeferred()), "daily", FeedSort.POST_TIME)
        oldCall.reply.gate!!.complete(Unit)
        repeat(100) { yield() }
        verify(snapshots.getValue("daily-1").size == oldSnapshotCount, "old cancelled observation cannot publish into the new pull")
        verify(current.terminal == null, "old release cannot finish current held pull")
        finishPull(current, "daily", FeedSort.POST_TIME)
        stage = "daily-immediate-same-pager"
        finishPull(startPull("daily-2", Reply(13), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-same-id-changed-title"
        finishPull(startPull("daily-2", Reply(13, "changed title", CompletableDeferred()), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-identical-again"
        finishPull(startPull("daily-2", Reply(13, "changed title", CompletableDeferred()), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-error-keeps-cache"
        finishPull(startPull("daily-2", Reply(14, gate = CompletableDeferred(), fail = true), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-recovery-empty"
        finishPull(startPull("daily-2", Reply(14, gate = CompletableDeferred(), empty = true), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        stage = "daily-empty-to-empty"
        finishPull(startPull("daily-2", Reply(14, gate = CompletableDeferred(), empty = true), "daily", FeedSort.POST_TIME), "daily", FeedSort.POST_TIME)
        close("daily-2")
        trace("summary", "seedCalls" to JsonPrimitive(seeded), "actualRemoteCalls" to JsonPrimitive(calls.size), "problems" to JsonArray(problems.map(::JsonPrimitive)))
        check(problems.isEmpty()) { "BEHAVIORAL RED: ${problems.joinToString("; ")}" }
        println("PASS retained production paging.refresh across all->daily->another->daily; held old cancellation/new pull, repeated same presenter, identical/changed/empty/error")
    } finally {
        jobs.values.forEach { it.cancel() }
        jobs.values.forEach { it.join() }
        db.close()
    }
}
