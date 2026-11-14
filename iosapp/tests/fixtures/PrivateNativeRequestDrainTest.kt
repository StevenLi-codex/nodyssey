package io.github.nodyssey.ios.native

import kotlinx.coroutines.*
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class PrivateNativeRequestDrainTest {
    @Test fun cancelDoesNotAcknowledgeFileReleaseBeforeFinallyCompletes() = runBlocking {
        Dispatchers.setMain(Dispatchers.Unconfined)
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val finished = CompletableDeferred<Unit>()
        val job = launch {
            try { entered.complete(Unit); awaitCancellation() }
            finally { withContext(NonCancellable) { release.await() } }
        }
        try {
            entered.await()
            val request = NativeRequest(job)
            request.invokeOnCompletion { finished.complete(Unit) }
            request.cancel()
            yield()
            assertFalse(finished.isCompleted, "File must remain while finally can consume it")
            release.complete(Unit)
            withTimeout(2000) { finished.await() }
            assertTrue(job.isCompleted)
            val late = CompletableDeferred<Unit>()
            request.invokeOnCompletion { late.complete(Unit) }
            withTimeout(2000) { late.await() }
        } finally {
            release.complete(Unit)
            job.cancelAndJoin()
            Dispatchers.resetMain()
        }
    }
}
