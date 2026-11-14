@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package io.github.nodyssey.ios.native

import androidx.paging.LoadState
import androidx.paging.PagingData
import androidx.paging.PagingDataEvent
import androidx.paging.PagingDataPresenter
import io.github.nodyssey.core.NodeSeekStickers
import io.github.nodyssey.data.FeedPost
import io.github.nodyssey.data.NotificationCategory
import io.github.nodyssey.data.NotificationSource
import io.github.nodyssey.data.ReadingPosition
import io.github.nodyssey.data.composer.CommentDraft
import io.github.nodyssey.data.composer.CommentSubmission
import io.github.nodyssey.data.composer.ImageAttachment
import io.github.nodyssey.data.composer.PostDraft
import io.github.nodyssey.data.composer.PostEditContent
import io.github.nodyssey.data.composer.PostEditTarget
import io.github.nodyssey.data.composer.PostPermission
import io.github.nodyssey.data.composer.PostSubmission
import io.github.nodyssey.model.FeedSort
import io.github.nodyssey.model.ReactionAction
import io.github.plaza.core.richtext.parseMarkdown
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlin.coroutines.CoroutineContext

private val nativePagingSessions = NativePagingSessions()
private val nativeMutationGate = NativeMutationGate()

// Invalidation signals, NOT data caches. Content always comes from existing repositories.
private val nativeNotificationRevision = MutableStateFlow(0L)
private val nativeMessageRevision = MutableStateFlow(0L)

internal class NativeMutationGate {
    private val running = mutableSetOf<String>()
    suspend fun <T> run(key: String, block: suspend () -> T): T {
        if (!running.add(key)) throw NativeFailure("BUSY")
        try {
            return block()
        } finally {
            running.remove(key)
        }
    }
}

private val nativeContentMutations = setOf(
    "thread.markRead", "thread.position.set", "thread.react", "thread.collect",
    "vote.submit", "vote.create", "vote.lock", "vote.delete",
    "editor.post.publish", "editor.comment.publish", "editor.edit.save", "editor.image.upload",
    "draft.post.save", "draft.post.delete", "draft.comment.save", "draft.comment.delete",
    "notifications.read", "notifications.readAll", "messages.read", "messages.readAll", "messages.send",
)

internal suspend fun NativeContext.contentRequest(operation: String, args: JsonObject): JsonElement? =
    if (operation in nativeContentMutations) {
        // Sorted JSON gives equivalent object arguments the same in-flight identity. No automatic
        // retries or persisted idempotency claim: an interrupted write may have reached the server.
        nativeMutationGate.run(operation + nativeCanonicalArguments(args)) { contentExecute(operation, args) }
    } else {
        contentExecute(operation, args)
    }

private fun nativeCanonicalArguments(value: JsonElement): String = when (value) {
    is JsonObject -> value.entries.sortedBy { it.key }.joinToString(",", "{", "}") { JsonPrimitive(it.key).toString() + ":" + nativeCanonicalArguments(it.value) }
    is JsonArray -> value.joinToString(",", "[", "]", transform = ::nativeCanonicalArguments)
    else -> value.toString()
}

private suspend fun NativeContext.contentExecute(op: String, a: JsonObject): JsonElement? {
    val posts = graph.postRepository
    return when (op) {
        "categories.get" -> nativeContentArray(graph.categoryRepository.boards.first(), ::nativeContentJson)

        "categories.refresh" -> {
            graph.categoryRepository.refreshIfNeeded()
            nativeContentArray(graph.categoryRepository.boards.first(), ::nativeContentJson)
        }

        "feed.pageIndex" -> nativeContentObject("index" to posts.feedRowIndexOfPage(a.nativeOptionalText("categorySlug"), a.nativeEnum("sort", FeedSort.LAST_REPLY), a.nativePage()))

        "paging.access", "paging.refresh", "paging.retry" -> {
            val presenter = nativePagingSessions.get(a.nativeText("pagerId"))
            when (op) {
                "paging.access" -> {
                    val index = a.nativeInt("index")
                    if (index !in 0 until presenter.size) throw NativeFailure("INVALID_ARGUMENT")
                    presenter[index] // Paging's access hint is the ONLY append/prepend mechanism.
                }

                "paging.refresh" -> presenter.refresh()

                else -> presenter.retry()
            }
            JsonNull
        }

        "search.local" -> nativeContentArray(posts.search(a.nativeText("query")).first(), ::nativeContentJson)

        "search.users" -> nativeContentArray(graph.searchRepository.searchUsers(a.nativeText("query")), ::nativeContentJson)

        "search.resolveMember" -> nativeContentObject("uid" to graph.searchRepository.resolveMemberUid(a.nativeText("name")))

        "thread.get", "thread.config" -> posts.thread(a.nativeId("postId")).first()?.let(::nativeContentJson) ?: JsonNull

        "thread.load" -> {
            val id = a.nativeId("postId")
            val page = a.nativePage()
            if (a.nativeBoolean("extend", false)) posts.extendThread(id, page) else posts.refreshThread(id, page)
            posts.thread(id).first()?.let(::nativeContentJson) ?: JsonNull
        }

        "thread.reconcileReactions" -> nativeContentJson(posts.reconcileThreadReactions(a.nativeId("postId"), a.nativePage()))

        "thread.status" -> {
            val id = a.nativeId("postId")
            val pages = posts.cachedPages(id)
            nativeContentObject(
                "isThreadFresh" to posts.isThreadFresh(id),
                "seenRepliesIfUnread" to posts.seenRepliesIfUnread(id),
                "firstLoadedPage" to pages?.first,
                "lastLoadedPage" to pages?.last,
            )
        }

        "thread.markRead" -> {
            posts.markThreadRead(a.nativeId("postId"))
            JsonNull
        }

        "thread.position.get" -> graph.readingPositionStore.readingPosition(a.nativeId("postId"))?.let(::nativeContentJson) ?: JsonNull

        "thread.position.set" -> {
            graph.readingPositionStore.setReadingPosition(a.nativeId("postId"), ReadingPosition(a.nativePage(), a.nativeOptionalText("floor")))
            JsonNull
        }

        "thread.react" -> {
            posts.react(a.nativeId("postId"), a.nativeId("commentId"), a.nativeEnum<ReactionAction>("action"))
            JsonNull
        }

        "thread.freeChickenLegs" -> posts.freeChickenLegs()?.let(::nativeContentJson) ?: JsonNull

        "thread.collect" -> {
            posts.setCollected(a.nativeId("postId"), a.nativeBoolean("collected"))
            JsonNull
        }

        "vote.get" -> nativeContentJson(graph.voteRepository.info(a.nativeId("voteId")))

        "vote.submit" -> {
            graph.voteRepository.submit(a.nativeId("voteId"), a.nativeIds("itemIds"))
            JsonNull
        }

        "vote.create" -> nativeContentObject("id" to graph.voteRepository.create(a.nativeText("title"), a.nativeBoolean("multiple"), a.nativeBoolean("isPublic"), a.nativeStrings("items")))

        "vote.lock" -> {
            graph.voteRepository.setLocked(a.nativeId("voteId"), a.nativeBoolean("locked"))
            JsonNull
        }

        "vote.delete" -> {
            graph.voteRepository.delete(a.nativeId("voteId"))
            JsonNull
        }

        "vote.voters" -> nativeContentLongs(graph.voteRepository.voters(a.nativeId("itemId"), a.nativePage()))

        "editor.preview" -> withContext(graph.dispatchers.default) { nativeRichNodes(parseMarkdown(a.nativeText("body"), NodeSeekStickers::urlFor)) }

        "editor.permissions" -> nativeContentArray(PostPermission.options(a.nativeOptionalInt("selfRank"))) { JsonPrimitive(it.wireValue) }

        "editor.post.publish" -> nativeContentObject(
            "postId" to graph.postComposerRepository.publish(
                PostSubmission(a.nativeText("title"), a.nativeText("body"), a.nativeText("boardSlug"), a.nativePermission()),
            ),
        )

        "editor.comment.publish" -> nativeContentObject(
            "floor" to graph.commentComposerRepository.publish(
                CommentSubmission(a.nativeId("postId"), a.nativeText("body"), a.nativeOptionalInt("quotedFloor")),
            ),
        )

        "editor.edit.load" -> nativeContentJson(graph.postEditor.load(a.nativeEditTarget()))

        "editor.edit.save" -> {
            graph.postEditor.save(a.nativeEditTarget(), PostEditContent(a.nativeText("title"), a.nativePermission(), a.nativeText("body")))
            JsonNull
        }

        "editor.image.upload" -> {
            val source = a.nativeText("source")
            if (!source.startsWith("file://")) throw NativeFailure("INVALID_ARGUMENT")
            val attachment = ImageAttachment(a.nativeText("id"), source, a.nativeText("name"))
            val url = graph.imageUploader.upload(attachment) { /* One-shot ABI; no synthetic progress. */ }
            nativeContentObject("id" to attachment.id, "remoteUrl" to url, "markdown" to attachment.copy(remoteUrl = url).markdown)
        }

        "draft.post.get" -> graph.postComposerRepository.draft.first()?.let(::nativeContentJson) ?: JsonNull

        "draft.post.save" -> {
            graph.postComposerRepository.saveDraft(PostDraft(a.nativeText("title"), a.nativeText("body"), a.nativeOptionalText("boardSlug"), a.nativeOptionalText("boardTitle"), a.nativePermission()))
            JsonNull
        }

        "draft.post.delete" -> {
            graph.postComposerRepository.deleteDraft()
            JsonNull
        }

        "draft.comment.get" -> graph.commentComposerRepository.draft(a.nativeId("postId")).first()?.let(::nativeContentJson) ?: JsonNull

        "draft.comment.save" -> {
            graph.commentComposerRepository.saveDraft(a.nativeId("postId"), CommentDraft(a.nativeText("body"), a.nativeOptionalInt("replyToFloor"), a.nativeOptionalText("replyToAuthor"), a.nativeOptionalText("replyToText")))
            JsonNull
        }

        "draft.comment.delete" -> {
            graph.commentComposerRepository.deleteDraft(a.nativeId("postId"))
            JsonNull
        }

        "notifications.list" -> nativeLoadNotifications(a)

        "notifications.counts" -> nativeContentJson(graph.notificationRepository.counts.value)

        "notifications.refresh" -> {
            val counts = graph.notificationRepository.refreshCounts()
            nativeNotificationRevision.value++
            nativeContentJson(counts)
        }

        "notifications.read" -> {
            graph.notificationRepository.markViewed(
                a.nativeArray("sources").map { item ->
                    val source = item as? JsonObject ?: throw NativeFailure("INVALID_ARGUMENT")
                    val category = source.nativeEnum<NotificationCategory>("category")
                    if (category == NotificationCategory.MESSAGES) throw NativeFailure("INVALID_ARGUMENT")
                    NotificationSource(category, source.nativeOptionalLong("viewedId"), source.nativeBoolean("isUnread"))
                },
            )
            nativeNotificationRevision.value++
            JsonNull
        }

        "notifications.readAll" -> {
            val category = a.nativeEnum<NotificationCategory>("category")
            if (category == NotificationCategory.MESSAGES) throw NativeFailure("INVALID_ARGUMENT")
            graph.notificationRepository.markAllRead(category)
            nativeNotificationRevision.value++
            JsonNull
        }

        "messages.list" -> nativeContentArray(graph.messageRepository.conversations(), ::nativeContentJson)

        "messages.thread" -> nativeContentJson(graph.messageRepository.thread(a.nativeId("uid")))

        "messages.refresh" -> {
            nativeMessageRevision.value++
            JsonNull
        }

        "messages.read" -> {
            graph.messageRepository.markRead(a.nativeIds("messageIds"))
            nativeMessageRevision.value++
            JsonNull
        }

        "messages.readAll" -> {
            graph.messageRepository.markAllRead()
            nativeMessageRevision.value++
            JsonNull
        }

        "messages.send" -> {
            val accepted = graph.messageRepository.send(a.nativeId("uid"), a.nativeText("content"), a.nativeBoolean("markdown"))
            nativeMessageRevision.value++
            accepted?.let(::nativeContentJson) ?: JsonNull
        }

        else -> null
    }
}

internal fun NativeContext.contentObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when (operation) {
    "feed" -> {
        val slug = args.nativeOptionalText("categorySlug")
        val sort = args.nativeEnum("sort", FeedSort.LAST_REPLY)
        val page = args.nativePage()
        nativePagingFlow(args.nativeText("pagerId"), graph.postRepository.feed(slug, sort, page), graph.postRepository.feedTotalPages(slug, sort), page)
    }

    "search.feed" -> nativePagingFlow(args.nativeText("pagerId"), graph.postRepository.searchFeed(args.nativeText("query"), args.nativeOptionalText("categorySlug"), args.nativeEnum("sort", FeedSort.LAST_REPLY)), null, 1)

    "search.local" -> graph.postRepository.search(args.nativeText("query")).map { nativeContentArray(it, ::nativeContentJson) }

    "categories" -> graph.categoryRepository.boards.map { nativeContentArray(it, ::nativeContentJson) }

    "thread", "thread.config" -> graph.postRepository.thread(args.nativeId("postId")).map { it?.let(::nativeContentJson) ?: JsonNull }

    "draft.post" -> graph.postComposerRepository.draft.map { it?.let(::nativeContentJson) ?: JsonNull }

    "draft.comment" -> graph.commentComposerRepository.draft(args.nativeId("postId")).map { it?.let(::nativeContentJson) ?: JsonNull }

    "notifications.counts" -> graph.notificationRepository.counts.map(::nativeContentJson)

    "notifications.list" -> nativeNotificationRevision.mapLatest { nativeLoadNotifications(args) }

    "messages.list" -> nativeMessageRevision.mapLatest { nativeContentArray(graph.messageRepository.conversations(), ::nativeContentJson) }

    "messages.thread" -> {
        val uid = args.nativeId("uid")
        nativeMessageRevision.mapLatest { nativeContentJson(graph.messageRepository.thread(uid)) }
    }

    else -> null
}

private suspend fun NativeContext.nativeLoadNotifications(a: JsonObject): JsonElement {
    val category = a.nativeOptionalText("category")
    val rows = if (category == null) {
        graph.notificationRepository.interactions()
    } else {
        val value = a.nativeEnum<NotificationCategory>("category")
        if (value == NotificationCategory.MESSAGES) throw NativeFailure("INVALID_ARGUMENT")
        graph.notificationRepository.notifications(value)
    }
    return nativeContentArray(rows, ::nativeContentJson)
}

private fun JsonObject.nativePermission(): PostPermission = PostPermission(
    nativeInt("permission").also {
        if (it !in 0..255) throw NativeFailure("INVALID_ARGUMENT")
    },
)
private fun JsonObject.nativeEditTarget(): PostEditTarget = PostEditTarget(nativeId("postId"), nativeId("commentId"), nativePage(), nativeBoolean("isOpeningPost"))
private fun JsonObject.nativeOptionalLong(key: String): Long? = if (this[key] == null || this[key] == JsonNull) null else nativeLong(key)
private fun JsonObject.nativeOptionalInt(key: String): Int? = if (this[key] == null || this[key] == JsonNull) null else nativeInt(key)
private fun JsonObject.nativeIds(key: String): List<Long> = nativeArray(key).map {
    nativeContentObject("id" to it).nativeId("id")
}
private fun JsonObject.nativeStrings(key: String): List<String> = nativeArray(key).map {
    nativeContentObject("text" to it).nativeText("text")
}

/** Main-confined handles, not a second post cache. Entries live only while their observation lives. */
internal class NativePagingSessions {
    private val presenters = mutableMapOf<String, PagingDataPresenter<FeedPost>>()
    fun contains(id: String): Boolean = presenters.containsKey(id)
    fun get(id: String): PagingDataPresenter<FeedPost> = presenters[id] ?: throw NativeFailure("PAGER_CLOSED")
    fun add(id: String, presenter: PagingDataPresenter<FeedPost>) {
        if (id.isBlank()) throw NativeFailure("INVALID_ARGUMENT")
        if (presenters.containsKey(id)) throw NativeFailure("PAGER_IN_USE")
        presenters[id] = presenter
    }
    fun remove(id: String, presenter: PagingDataPresenter<FeedPost>) {
        if (presenters[id] === presenter) presenters.remove(id)
    }
}

/** Paging 3.5.1 common API, verified against the pinned sources, not Android AsyncPagingDataDiffer. */
internal fun nativePagingFlow(
    id: String,
    data: Flow<PagingData<FeedPost>>,
    totals: Flow<Int>?,
    page: Int,
    sessions: NativePagingSessions = nativePagingSessions,
    mainContext: CoroutineContext = Dispatchers.Main,
): Flow<JsonElement> = channelFlow {
    var totalPages: Int? = null
    lateinit var presenter: PagingDataPresenter<FeedPost>
    fun nativeSnapshot(): JsonObject {
        val snapshot = presenter.snapshot()
        val states = presenter.loadStateFlow.value
        return nativeContentObject(
            "pagerId" to id, "items" to nativeContentArray(snapshot.items, ::nativeContentJson),
            "placeholdersBefore" to snapshot.placeholdersBefore, "placeholdersAfter" to snapshot.placeholdersAfter,
            "itemCount" to snapshot.size, "page" to page, "totalPages" to totalPages,
            "refresh" to nativeLoadState(states?.refresh), "append" to nativeLoadState(states?.append), "prepend" to nativeLoadState(states?.prepend),
        )
    }
    presenter = object : PagingDataPresenter<FeedPost>(mainContext) {
        override suspend fun presentPagingDataEvent(event: PagingDataEvent<FeedPost>) {
            send(nativeSnapshot())
        }
    }
    sessions.add(id, presenter)
    try {
        launch { presenter.loadStateFlow.collect { send(nativeSnapshot()) } }
        if (totals != null) {
            launch {
                totals.collect {
                    totalPages = it
                    send(nativeSnapshot())
                }
            }
        }
        data.collectLatest { presenter.collectFrom(it) }
        // Static/empty PagingData can finish; the Swift subscription still owns its handle.
        awaitCancellation()
    } finally {
        sessions.remove(id, presenter)
    }
}.buffer(kotlinx.coroutines.channels.Channel.CONFLATED)

private fun nativeLoadState(state: LoadState?): JsonObject = when (state) {
    null -> nativeContentObject("status" to "Idle")
    is LoadState.Loading -> nativeContentObject("status" to "Loading")
    is LoadState.NotLoading -> nativeContentObject("status" to "NotLoading", "endOfPaginationReached" to state.endOfPaginationReached)
    is LoadState.Error -> nativeContentObject("status" to "Error", "error" to Json.parseToJsonElement(nativeFailure(state.error)).jsonObject["error"])
}
