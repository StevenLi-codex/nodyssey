package io.github.nodyssey.ios.native

import androidx.room.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.github.nodyssey.data.*
import io.github.nodyssey.data.local.NodeSeekDatabase
import io.github.nodyssey.model.*
import io.github.plaza.core.AppClock
import io.github.plaza.core.net.SiteError
import io.github.plaza.core.net.SiteException
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
import java.io.File

/** Exact production repository + Room/SQLite + native dispatch/mapping, fixture I/O only. */
fun main(args: Array<String>) = runBlocking {
    val db = Room.databaseBuilder<NodeSeekDatabase>(args[0]).setDriver(BundledSQLiteDriver()).build()
    fun floor(id: Long, number: String, liked: Boolean = false) = PostContent(
        id, number, "fixture", 1, null, false, emptyList(), null, null, null, emptyList(),
        reactions = PostReactions(liked = liked),
    )
    fun page(number: Int, liked: Boolean = false) = PostDetail(
        42, "fixture thread", if (number == 1) floor(6, "#0", liked) else null,
        listOf(floor(if (number == 1) 7 else 8, if (number == 1) "#1" else "#11", liked)), number, 3, number < 3,
    )
    var offline = false
    var omitReactions = false
    var spent = false
    var storedReads = 0
    var networkReads = 0
    var transform: (PostDetail) -> PostDetail = { it }
    var networkGate: CompletableDeferred<Unit>? = null
    var networkStarted: CompletableDeferred<Unit>? = null
    val remote = object : PostRemoteDataSource {
        override suspend fun loadList(categorySlug: String?, page: Int, sort: FeedSort): PostListPage = error("not used")
        override suspend fun loadSearch(query: String, page: Int, categorySlug: String?, sort: FeedSort): PostListPage = error("not used")
        override suspend fun loadDetail(postId: Long, page: Int): PostDetail {
            networkReads++
            if (offline) throw SiteException(SiteError.Network)
            networkStarted?.complete(Unit)
            networkGate?.await()
            val result = transform(page(page, spent))
            return if (omitReactions) result.copy(body = result.body?.copy(reactions = null), comments = result.comments.map { it.copy(reactions = null) }) else result
        }
    }
    val repository = OfflineFirstPostRepository(db, remote, object : AppClock { override fun nowMillis() = 100_000L },
        offlineThreads = object : OfflineThreadReader {
            override suspend fun storedPage(postId: Long, page: Int): StoredThreadPage {
                storedReads++
                return StoredThreadPage(page(page), 100L)
            }
        })
    suspend fun call(op: String, page: Int, extend: Boolean = false): JsonElement = fixtureThreadRequest(repository, op,
        buildJsonObject { put("postId", 42); put("page", page); put("extend", extend) })
    val evidence = linkedMapOf<String, JsonElement>()
    try {
        // A downloaded unspent copy must remain readable through the normal path.
        offline = true
        evidence["offlineSnapshot"] = call("thread.load", 1)
        check(repository.thread(42).first()!!.comments.single().reactions!!.liked.not())
        check(storedReads == 1)
        println("PASS normal load uses real repository offline fallback")
        offline = false
        evidence["mergedSnapshot"] = call("thread.load", 2, true)
        val merged = repository.thread(42).first()!!
        check(merged.commentPages == listOf(1, 2))
        check(merged.comments.first().commentId == 7L && !merged.comments.first().reactions!!.liked)
        evidence["replacementSnapshot"] = call("thread.load", 2, false)
        check(repository.thread(42).first()!!.body!!.commentId == 6L)
        println("PASS actual merged and replaced windows retain stale affected floor or opening body")
        File(args[1]).writeText(JsonObject(evidence).toString())
        if (args.getOrNull(2) == "--baseline-only") return@runBlocking
        offline = true
        val before = storedReads
        val failure = runCatching { call("thread.reconcileReactions", 1) }.exceptionOrNull()
        check(failure is SiteException && failure.error == SiteError.Network) { "Dedicated network read must throw Network, got $failure" }
        check(storedReads == before) { "Reconciliation consulted offline reader" }
        evidence["offlineReadError"] = JsonPrimitive("NETWORK")
        println("PASS dedicated network read refuses fallback")
        offline = false
        evidence["otherPageReceipt"] = call("thread.reconcileReactions", 2)
        val other = evidence.getValue("otherPageReceipt").jsonObject
        check(other["commentIds"]!!.jsonArray == JsonArray(listOf(JsonPrimitive(8))))
        check(other["openingCommentId"] == JsonNull)
        println("PASS merged stale page and retained opening body excluded from coverage")
        evidence["replacementSnapshot"] = call("thread.load", 2, false)
        check(repository.thread(42).first()!!.body!!.commentId == 6L)
        omitReactions = true
        evidence["missingConfigReceipt"] = call("thread.reconcileReactions", 1)
        val missing = evidence.getValue("missingConfigReceipt").jsonObject
        check(missing["commentIds"]!!.jsonArray.isEmpty() && missing["openingCommentId"] == JsonNull)
        println("PASS no account reaction config provides no coverage")
        omitReactions = false
        spent = true
        val count = networkReads
        evidence["relevantReceipt"] = call("thread.reconcileReactions", 1)
        check(networkReads == count + 1)
        val fresh = evidence.getValue("relevantReceipt").jsonObject
        check(fresh["commentIds"]!!.jsonArray == JsonArray(listOf(JsonPrimitive(7))))
        check(fresh["openingCommentId"]!!.jsonPrimitive.long == 6L)
        check(repository.thread(42).first()!!.comments.first().reactions!!.liked)
        println("PASS relevant new network response persists spent state and exact coverage")
        for (wrongPost in listOf(true, false)) {
            val prior = repository.thread(42).first()
            transform = { if (wrongPost) it.copy(postId = 43) else it.copy(page = 2) }
            check(runCatching { call("thread.reconcileReactions", 1) }.exceptionOrNull() is IllegalArgumentException)
            check(repository.thread(42).first() == prior) { "Mismatched response wrote cache" }
        }
        println("PASS post and page mismatch reject before persistence")
        transform = { it.copy(body = it.body?.copy(commentId = null), comments = it.comments + floor(9, "#2").copy(commentId = null)) }
        val nullable = call("thread.reconcileReactions", 1).jsonObject
        check(nullable["commentIds"]!!.jsonArray == JsonArray(listOf(JsonPrimitive(7))))
        check(nullable["openingCommentId"] == JsonNull)
        println("PASS nullable comment and opening identities omitted")
        transform = { it }
        val prior = repository.thread(42).first()
        networkGate = CompletableDeferred()
        networkStarted = CompletableDeferred()
        var delivered = false
        val pending = launch { call("thread.reconcileReactions", 1); delivered = true }
        networkStarted.await()
        pending.cancelAndJoin()
        check(!delivered && repository.thread(42).first() == prior)
        networkGate = null
        networkStarted = null
        println("PASS cancelled network read returns no receipt and leaves cache unchanged")
        val readsBeforeInvalid = networkReads
        check(runCatching { repository.reconcileThreadReactions(0, 1) }.exceptionOrNull() is IllegalArgumentException)
        check(runCatching { repository.reconcileThreadReactions(42, 0) }.exceptionOrNull() is IllegalArgumentException)
        check(networkReads == readsBeforeInvalid)
        println("PASS invalid request identities rejected before network")
        offline = true
        val beforeExtend = storedReads
        call("thread.load", 2, true)
        check(storedReads == beforeExtend + 1)
        println("PASS normal extend preserves offline fallback")
        offline = false
        db.close()
        val beforeClosed = networkReads
        check(runCatching { call("thread.reconcileReactions", 1) }.isFailure) { "Persistence failure returned a receipt" }
        check(networkReads == beforeClosed + 1)
        println("PASS real Room persistence failure returns no receipt")
        File(args[1]).writeText(JsonObject(evidence).toString())
    } finally { db.close() }
}
