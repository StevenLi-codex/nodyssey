package io.github.nodyssey.data.session

import androidx.paging.PagingData
import io.github.nodyssey.data.*
import io.github.nodyssey.model.*
import kotlinx.coroutines.flow.Flow

/** iOS opt-in. Control-plane cleanup uses the raw repository only after joined revocation. */
class PrivatePostRepository(private val delegate: PostRepository, private val boundary: PrivateSessionBoundary) : PostRepository {
    override fun feed(categorySlug: String?, sort: FeedSort, startPage: Int, forceInitialRefresh: Boolean): Flow<PagingData<FeedPost>> {
        val flow = delegate.feed(categorySlug, sort, startPage, forceInitialRefresh)
        return if (flow is io.github.nodyssey.data.FeedPagingFlow) {
            io.github.nodyssey.data.FeedPagingFlow(boundary.protect(flow.generations))
        } else boundary.protect(flow)
    }
    override fun feedTotalPages(categorySlug: String?, sort: FeedSort): Flow<Int> = boundary.protect(delegate.feedTotalPages(categorySlug, sort))
    override suspend fun feedRowIndexOfPage(categorySlug: String?, sort: FeedSort, page: Int): Int? = boundary.protect { delegate.feedRowIndexOfPage(categorySlug, sort, page) }
    override fun searchFeed(query: String, categorySlug: String?, sort: FeedSort): Flow<PagingData<FeedPost>> = boundary.protect(delegate.searchFeed(query, categorySlug, sort))
    override fun search(query: String): Flow<List<FeedPost>> = boundary.protect(delegate.search(query))
    override suspend fun invalidateCaches(): Unit = boundary.protect { delegate.invalidateCaches() }
    override suspend fun clearSessionData(): Unit = boundary.protect { delegate.clearSessionData() }
    override suspend fun clearCache(isSignedIn: Boolean, fingerprint: Int): Unit = boundary.protect { delegate.clearCache(isSignedIn, fingerprint) }
    override suspend fun reconcileSession(isSignedIn: Boolean, fingerprint: Int): Boolean = boundary.protect { delegate.reconcileSession(isSignedIn, fingerprint) }
    override fun thread(postId: Long): Flow<ThreadSnapshot?> = boundary.protect(delegate.thread(postId))
    override suspend fun refreshThread(postId: Long, page: Int): Unit = boundary.protect { delegate.refreshThread(postId, page) }
    override suspend fun extendThread(postId: Long, page: Int): Unit = boundary.protect { delegate.extendThread(postId, page) }
    override suspend fun reconcileThreadReactions(postId: Long, page: Int): ThreadReactionRead = boundary.protect { delegate.reconcileThreadReactions(postId, page) }
    override suspend fun isThreadFresh(postId: Long): Boolean = boundary.protect { delegate.isThreadFresh(postId) }
    override suspend fun seenRepliesIfUnread(postId: Long): Int? = boundary.protect { delegate.seenRepliesIfUnread(postId) }
    override suspend fun cachedPages(postId: Long): IntRange? = boundary.protect { delegate.cachedPages(postId) }
    override suspend fun markThreadRead(postId: Long): Unit = boundary.protect { delegate.markThreadRead(postId) }
    override suspend fun noteOwnReplyPublished(postId: Long): Unit = boundary.protect { delegate.noteOwnReplyPublished(postId) }
    override suspend fun react(postId: Long, commentId: Long, action: ReactionAction): Unit = boundary.protect { delegate.react(postId, commentId, action) }
    override suspend fun freeChickenLegs(): FreeChickenLegs? = boundary.protect { delegate.freeChickenLegs() }
    override suspend fun setCollected(postId: Long, collected: Boolean): Unit = boundary.protect { delegate.setCollected(postId, collected) }
    override fun readHistory(): Flow<List<ReadHistoryEntry>> = boundary.protect(delegate.readHistory())
    override suspend fun removeFromHistory(postId: Long): Unit = boundary.protect { delegate.removeFromHistory(postId) }
    override suspend fun restoreToHistory(entry: ReadHistoryEntry): Unit = boundary.protect { delegate.restoreToHistory(entry) }
    override suspend fun trimReadHistory(): Unit = boundary.protect { delegate.trimReadHistory() }
    override suspend fun clearReadHistory(): Unit = boundary.protect { delegate.clearReadHistory() }
}
