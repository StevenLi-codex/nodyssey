package io.github.nodyssey.data.session

import io.github.nodyssey.data.OfflineLibrary
import io.github.nodyssey.data.OfflineSettings
import io.github.nodyssey.data.OfflineThreadReader
import io.github.nodyssey.data.offline.OfflineDownloads
import io.github.nodyssey.data.offline.RoomOfflineLibrary

/** Opt-in adapter: existing Room engine/DAOs remain SSOT and Android constructors are unchanged. */
class PrivateOfflineLibrary(
    private val raw: RoomOfflineLibrary,
    private val boundary: PrivateSessionBoundary,
) : OfflineLibrary by raw, OfflineThreadReader, OfflineDownloads {
    override val states = boundary.protect(raw.states)
    override val usage = boundary.protect(raw.usage)
    override suspend fun download(postIds: Collection<Long>) = boundary.protect { raw.download(postIds) }
    override suspend fun noteReplyCounts(counts: Map<Long, Int>) = boundary.protect { raw.noteReplyCounts(counts) }
    override suspend fun estimateBytes(postIds: Collection<Long>) = boundary.protect { raw.estimateBytes(postIds) }
    override suspend fun cancel(postId: Long) = boundary.protect { raw.cancel(postId) }
    override suspend fun clearAll() = boundary.protect { raw.clearAll() }
    override suspend fun updateSettings(settings: OfflineSettings) = boundary.protect { raw.updateSettings(settings) }
    override suspend fun storedPage(postId: Long, page: Int) = boundary.protect { raw.storedPage(postId, page) }
    override suspend fun hasQueuedWork() = boundary.protect { raw.hasQueuedWork() }
    override suspend fun staleIds() = boundary.protect { raw.staleIds() }
    override suspend fun drainQueue() = boundary.protect { raw.drainQueue() }
    override suspend fun sweepExpired() = boundary.protect { raw.sweepExpired() }
}
