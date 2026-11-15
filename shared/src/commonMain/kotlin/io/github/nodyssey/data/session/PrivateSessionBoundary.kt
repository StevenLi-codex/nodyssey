package io.github.nodyssey.data.session

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.uuid.Uuid

class PrivateStoreParticipant(
    val id: String,
    val isEmpty: suspend () -> Boolean,
    val clear: suspend () -> Unit,
)

data class PrivateBoundaryState(
    val phase: PrivateStorePhase,
    val identityEpoch: String,
    val recoveryEligible: Boolean = false,
) {
    val requiresConfirmation: Boolean get() = phase != PrivateStorePhase.READY
}

/** Opt-in coordinator. No constructor side effects, no guessed legacy owner, no automatic deletion. */
class PrivateSessionBoundary(
    private val provenance: PrivateStoreProvenance,
    private val owner: () -> PrivateOwnerProof,
    private val participants: List<PrivateStoreParticipant>,
    private val beforePublication: suspend () -> Unit = {},
    private val publishSession: () -> Unit = {},
) {
    private val control = Mutex()
    private val barrier = SessionWorkBarrier()
    private val mutableState = MutableStateFlow(PrivateBoundaryState(PrivateStorePhase.UNKNOWN, newEpoch()))
    val state: StateFlow<PrivateBoundaryState> = mutableState.asStateFlow()
    private var verified: PrivateOwnerProof? = null
    private var observed: PrivateOwnerProof? = null

    init {
        require(participants.map { it.id }.toSet() == provenance.inventory)
        require(participants.map { it.id }.distinct().size == participants.size)
    }

    suspend fun reconcile() = controlled { reconcileLocked() }

    private suspend fun <T> controlled(block: suspend () -> T): T = control.withLock { whileControlled(block) }

    /** Publish recovery only after the operation, including its non-cancellable drains, ends. */
    private suspend fun <T> whileControlled(block: suspend () -> T): T {
        mutableState.value = state.value.copy(recoveryEligible = false)
        try {
            return block()
        } finally {
            mutableState.value = state.value.copy(
                recoveryEligible = external == null && state.value.phase != PrivateStorePhase.READY,
            )
        }
    }

    /** Non-blocking auth control: the active mutation's finally performs full reconciliation. */
    suspend fun reconcileIfIdle() {
        if (!control.tryLock()) return
        try {
            whileControlled { reconcileLocked() }
        } finally {
            control.unlock()
        }
    }

    private suspend fun reconcileLocked() {
        if (external != null) return
        val candidate = owner()
        if (observed == candidate) {
            publishSession()
            return
        }
        // Cache only completed reconciliation; a failed read/write/publication must be retried.
        observed = null
        // A failed journal read must not leave the old epoch's work running/admitted.
        invalidate(PrivateStorePhase.UNKNOWN) {}
        val manifest = provenance.load()
        // Only an intact complete manifest is evidence. Empty stores can establish fresh provenance;
        // an interrupted transition is never mistaken for a fresh installation.
        val same = manifest.phase == PrivateStorePhase.READY && manifest.owner == candidate.encoded &&
            manifest.completed == provenance.inventory
        val fresh = manifest.version == 0 && manifest.phase == PrivateStorePhase.UNKNOWN && manifest.owner == null &&
            participants.all { it.isEmpty() }
        if (manifest.phase == PrivateStorePhase.TRANSITIONING) {
            mutableState.value = state.value.copy(phase = PrivateStorePhase.TRANSITIONING)
        } else if (!same && !fresh) {
            provenance.unknown()
        }
        beforePublication()
        if (same || fresh) {
            if (candidate != owner()) return
            if (fresh) {
                val token = newEpoch()
                provenance.begin(candidate, token)
                participants.forEach { provenance.completed(token, it.id) }
                provenance.commit(token)
            }
            verified = candidate
            publishSession()
            barrier.open(state.value.identityEpoch)
            mutableState.value = state.value.copy(phase = PrivateStorePhase.READY)
        } else {
            publishSession()
        }
        observed = candidate
    }

    private data class Mutation(
        val proof: PrivateOwnerProof?,
        val observed: PrivateOwnerProof?,
        val state: PrivateBoundaryState,
        val token: String,
        val emptyAfterDrain: Boolean = false,
    )
    private var external: Mutation? = null

    private suspend fun beginMutation(): Mutation {
        val mutation = Mutation(verified, observed, state.value, newEpoch())
        // begin may throw/cancel before returning a Mutation to the caller's finally.
        // The journal and closed admission then remain the recovery authority.
        observed = null
        verified = null
        // A confirmation from before this writer started must not become usable after it drains.
        mutableState.value = PrivateBoundaryState(PrivateStorePhase.TRANSITIONING, newEpoch())
        barrier.closeAndJoin { provenance.begin(owner(), mutation.token) }
        // Inventory only after all old admitted writers have terminated. UNKNOWN/legacy or
        // interrupted journals never acquire an empty-store rebind capability through login.
        return mutation.copy(
            emptyAfterDrain = mutation.proof != null &&
                mutation.state.phase == PrivateStorePhase.READY && participants.all { it.isEmpty() },
        )
    }

    private suspend fun finishMutation(mutation: Mutation, allowEmptyRebind: Boolean = false) = withContext(NonCancellable) {
        val candidate = owner()
        beforePublication()
        val same = mutation.proof != null && mutation.proof == candidate && mutation.state.phase == PrivateStorePhase.READY
        val emptyRebind = !same && allowEmptyRebind && mutation.emptyAfterDrain && participants.all { it.isEmpty() }
        if ((same || emptyRebind) && candidate == owner()) {
            if (emptyRebind) provenance.begin(candidate, mutation.token)
            participants.forEach { provenance.completed(mutation.token, it.id) }
            provenance.commit(mutation.token)
            verified = candidate
            publishSession()
            // Same-cookie cancellation retains its epoch. A new auth proof must not revive
            // guest/old-account routes, even when there are no bytes to inherit.
            val ready = if (same) mutation.state else state.value.copy(phase = PrivateStorePhase.READY)
            barrier.open(ready.identityEpoch)
            mutableState.value = ready
        } else {
            verified = null
            provenance.unknown()
            mutableState.value = PrivateBoundaryState(
                PrivateStorePhase.UNKNOWN,
                state.value.identityEpoch,
            )
            publishSession()
        }
        observed = candidate
    }

    /** Serializes success/refusal/ordinary error/cancellation, never silently authorizing deletion. */
    suspend fun <T> sessionMutation(allowEmptyRebind: (T) -> Boolean = { false }, block: suspend () -> T): T = controlled {
        if (external != null) throw PrivateStoreAccessDenied()
        val mutation = beginMutation()
        var completed = false
        try {
            block().also { completed = allowEmptyRebind(it) }
        } finally {
            finishMutation(mutation, completed)
        }
    }

    /** The browser owns its network lifetime; retain this admission closure through final drain. */
    suspend fun beginExternalMutation() = controlled {
        if (external != null) throw PrivateStoreAccessDenied()
        external = beginMutation()
    }

    suspend fun finishExternalMutation(allowEmptyRebind: Boolean = false) = controlled {
        val mutation = external ?: return@controlled
        try {
            finishMutation(mutation, allowEmptyRebind)
        } finally {
            // The browser has drained. Publication/journal failure must remain recoverable
            // through reconcile/reset, not latch a finished external writer forever.
            external = null
        }
    }

    /** Explicit displayed-epoch confirmation only. Never call this as an authentication fallback. */
    suspend fun reset(confirmed: Boolean, expectedEpoch: String) {
        // Do not queue destructive intent behind an active writer or reset.
        if (!control.tryLock()) throw PrivateStoreAccessDenied()
        try {
            if (external != null || !confirmed || expectedEpoch != state.value.identityEpoch) throw PrivateStoreAccessDenied()
            whileControlled { resetLocked() }
        } finally {
            control.unlock()
        }
    }

    private suspend fun resetLocked() {
        val candidate = owner()
        val token = newEpoch()
        invalidate(PrivateStorePhase.TRANSITIONING) { provenance.begin(candidate, token) }
        // Cancellation/crash during cleanup deliberately leaves TRANSITIONING on disk.
        participants.forEach {
            it.clear()
            provenance.completed(token, it.id)
        }
        beforePublication()
        if (candidate != owner()) throw PrivateStoreAccessDenied()
        provenance.commit(token)
        verified = candidate
        publishSession()
        barrier.open(state.value.identityEpoch)
        mutableState.value = state.value.copy(phase = PrivateStorePhase.READY)
        observed = candidate
    }

    private suspend fun invalidate(phase: PrivateStorePhase, persist: suspend () -> Unit) {
        observed = null
        verified = null
        mutableState.value = PrivateBoundaryState(phase, newEpoch())
        barrier.closeAndJoin(persist)
    }

    /** Re-check the cookie authority even when a caller forgot session.sync(). */
    suspend fun <T> protect(block: suspend () -> T): T {
        val snapshot = state.value
        if (snapshot.phase != PrivateStorePhase.READY || verified != owner()) throw PrivateStoreAccessDenied()
        return barrier.withLease(snapshot.identityEpoch) {
            block().also { if (verified != owner()) throw PrivateStoreAccessDenied() }
        }
    }

    fun <T> protect(flow: Flow<T>): Flow<T> = channelFlow {
        // channelFlow permits the barrier lease to run in its child context while preserving
        // Flow's collector context for downstream consumers.
        protect {
            flow.collect { value ->
                if (verified != owner()) throw PrivateStoreAccessDenied()
                send(value)
            }
        }
    }

    private companion object {
        fun newEpoch(): String = Uuid.random().toString()
    }
}

/** Null means the pre-existing Android behavior, with no new admission or migration. */
suspend fun <T> PrivateSessionBoundary?.withPrivateAccess(block: suspend () -> T): T =
    if (this == null) block() else protect(block)

fun <T> PrivateSessionBoundary?.privateFlow(flow: Flow<T>): Flow<T> = if (this == null) flow else protect(flow)
