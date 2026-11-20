package io.github.nodyssey.ios.native

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Main-confined scheduling state owned by the existing NativeBridge process scope, not a data
 * cache. Repository refreshCounts publishes before returning, so every native count publisher
 * (including the refresh inside notification reads) must hold this mutex through actual drain.
 */
internal class NativeCountRefreshOwner(private val scope: CoroutineScope) {
    private val mutex = Mutex()
    private var pending: (suspend () -> Unit)? = null
    private var worker: Job? = null

    suspend fun <T> run(block: suspend () -> T): T = mutex.withLock {
        currentCoroutineContext().ensureActive()
        block()
    }

    /** Coalesce queued intentions, never discard an intention arriving during the active refresh. */
    fun request(block: suspend () -> Unit) {
        pending = block
        if (worker != null) return
        val nextWorker = scope.launch(start = CoroutineStart.LAZY) {
            try {
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val started = try {
                        // Admit and remove the latest intention while holding the same mutex as
                        // foreground publishers. Otherwise a foreground refresh can own the lock
                        // while several not-yet-started message intentions are removed one by one.
                        this@NativeCountRefreshOwner.run {
                            val next = pending ?: return@run false
                            pending = null
                            next()
                            true
                        }
                    } catch (cancelled: CancellationException) {
                        // A revoked private-boundary child lease may cancel independently. The
                        // process worker survives that drain, but never swallows its own cancellation.
                        currentCoroutineContext().ensureActive()
                        true
                    } catch (_: Exception) {
                        // Best effort only: message acknowledgements/rows do not depend on count IO.
                        true
                    }
                    if (!started) break
                }
            } finally {
                pending = null
                worker = null
            }
        }
        worker = nextWorker
        nextWorker.start()
    }
}
