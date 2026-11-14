package io.github.nodyssey.data.session

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.ThreadReactionRead
import kotlinx.coroutines.*
import org.junit.Test
import java.lang.reflect.Proxy
import kotlin.test.*

class PrivatePostBoundaryTest {
    @Test fun dedicatedReactionReadDelegatesOnlyInsideVerifiedJoinedLease() = runBlocking {
        val directory = kotlin.io.path.createTempDirectory("private-post-boundary").toFile()
        val storeScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val store = PreferenceDataStoreFactory.create(scope = storeScope) { directory.resolve("owner.preferences_pb") }
        var proof = PrivateOwnerProof("synthetic-A")
        var calls = 0
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var lateWrite = false
        val receipt = ThreadReactionRead(7, 2, listOf(21), null)
        val raw = Proxy.newProxyInstance(PostRepository::class.java.classLoader, arrayOf(PostRepository::class.java)) { _, method, _ ->
            if (method.name == "reconcileThreadReactions") { calls++; receipt } else error("Unexpected ${method.name}")
        } as PostRepository
        val boundary = PrivateSessionBoundary(PrivateStoreProvenance(store, emptySet()), { proof }, emptyList())
        val posts = PrivatePostRepository(raw, boundary)
        try {
            assertFailsWith<PrivateStoreAccessDenied> { posts.reconcileThreadReactions(7, 2) }
            assertEquals(0, calls)
            boundary.reconcile()
            assertEquals(receipt, posts.reconcileThreadReactions(7, 2))
            assertEquals(1, calls)
            val writer = launch {
                boundary.protect {
                    try { entered.complete(Unit); awaitCancellation() }
                    finally { withContext(NonCancellable) { release.await(); lateWrite = true } }
                }
            }
            entered.await()
            proof = PrivateOwnerProof("synthetic-B")
            val transition = async { boundary.reconcile() }
            yield()
            assertFalse(transition.isCompleted)
            assertFailsWith<PrivateStoreAccessDenied> { posts.reconcileThreadReactions(7, 2) }
            release.complete(Unit)
            transition.await(); writer.join()
            assertTrue(lateWrite)
            assertEquals(1, calls)
            assertFailsWith<PrivateStoreAccessDenied> { posts.reconcileThreadReactions(7, 2) }
        } finally { release.complete(Unit); storeScope.coroutineContext[Job]!!.cancelAndJoin(); directory.deleteRecursively() }
        Unit
    }
}
