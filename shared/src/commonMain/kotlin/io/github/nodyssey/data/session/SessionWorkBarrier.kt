package io.github.nodyssey.data.session

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

class PrivateWorkRevoked : CancellationException("Private epoch revoked")

class PrivateStoreAccessDenied : IllegalStateException("Private store requires recovery")

/** Join covers the entire structured operation, including non-cancellable callback drains. */
class SessionWorkBarrier {
    private val mutex = Mutex()
    private var admitted: String? = null
    private val jobs = mutableSetOf<Job>()
    private class Lease(val barrier: SessionWorkBarrier, val epoch: String) : AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<Lease>
    }

    suspend fun <T> withLease(epoch: String, block: suspend () -> T): T {
        val inherited = currentCoroutineContext()[Lease]
        if (inherited?.barrier === this) {
            checkLease(epoch)
            if (inherited.epoch != epoch) throw PrivateStoreAccessDenied()
            return block().also { checkLease(epoch) }
        }
        return coroutineScope {
            val job = currentCoroutineContext()[Job]!!
            mutex.withLock {
                if (admitted != epoch) throw PrivateStoreAccessDenied()
                jobs += job
            }
            try {
                withContext(Lease(this@SessionWorkBarrier, epoch)) {
                    block().also { checkLease(epoch) }
                }
            } finally {
                withContext(NonCancellable) { mutex.withLock { jobs -= job } }
            }
        }
    }

    suspend fun checkLease(epoch: String) {
        currentCoroutineContext().ensureActive()
        mutex.withLock { if (admitted != epoch) throw PrivateStoreAccessDenied() }
    }

    /** Control operations must never run in a reader lease (would cancel/join themselves). */
    suspend fun closeAndJoin(beforeJoin: suspend () -> Unit = {}) {
        check(currentCoroutineContext()[Lease]?.barrier !== this) { "Transition inside private lease" }
        val old = mutex.withLock {
            admitted = null
            jobs.toList()
        }
        // Persist untrusted status before allowing any cleanup, even if the caller is cancelled.
        withContext(NonCancellable) {
            try {
                beforeJoin()
            } finally {
                // Journal I/O failure is not permission to abandon already admitted writers.
                old.forEach { it.cancel(PrivateWorkRevoked()) }
                old.forEach { it.join() }
            }
        }
        currentCoroutineContext().ensureActive()
    }

    internal suspend fun open(epoch: String) {
        mutex.withLock {
            check(jobs.isEmpty())
            admitted = epoch
        }
    }
}
