package io.github.nodyssey.data.session

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import io.github.nodyssey.core.NodeSeekSite
import io.github.plaza.core.net.SessionCookieStore
import io.github.plaza.core.net.SessionCookies
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okio.Path.Companion.toPath
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PrivateBoundaryCoordinatorTest {
    private class Jar : SessionCookieStore {
        var account = "A"
        override fun cookieHeader(url: String) = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=$account"
        override fun setCookie(url: String, cookie: String) = error("No network writes")
        override suspend fun removeAll() {
            account = ""
        }
        override fun flush() = Unit
    }

    /** Fail at the real journal's I/O boundary, not in a replacement coordinator. */
    private class FaultStore(private val delegate: DataStore<Preferences>) : DataStore<Preferences> {
        var read: suspend () -> Unit = {}
        var write: suspend () -> Unit = {}
        override val data: Flow<Preferences> = flow {
            read()
            emitAll(delegate.data)
        }
        override suspend fun updateData(transform: suspend (Preferences) -> Preferences): Preferences {
            write()
            return delegate.updateData(transform)
        }
    }

    private class Fixture {
        val dir = File(System.getProperty("java.io.tmpdir"), "coordinator-${UUID.randomUUID()}").apply { mkdirs() }
        val job = SupervisorJob()
        fun store(name: String) = PreferenceDataStoreFactory.createWithPath(
            scope = CoroutineScope(job + Dispatchers.IO),
            produceFile = { File(dir, "$name.preferences_pb").path.toPath() },
        )
        val disk = store("journal")
        val faults = FaultStore(disk)
        val provenance = PrivateStoreProvenance(faults, setOf("draft"))
        val drafts = store("draft")
        val key = stringPreferencesKey("draft")
        val jar = Jar()
        val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
        var count = 9
        var clears = 0
        var before: suspend () -> Unit = {}
        var publishing: () -> Unit = {}
        val publications = mutableListOf<Int>()
        val boundary = PrivateSessionBoundary(
            provenance,
            session::privateOwnerProof,
            listOf(
                PrivateStoreParticipant("draft", { drafts.data.first().asMap().isEmpty() }, {
                    clears++
                    drafts.edit { it.remove(key) }
                }),
            ),
            {
                before()
                count = 0
            },
            {
                publishing()
                publications += count
                session.publishReconciled()
            },
        )
        suspend fun seed() {
            drafts.edit { it[key] = "legacy private draft" }
        }
        suspend fun preserved() {
            assertEquals("legacy private draft", drafts.data.first()[key])
            assertEquals(0, clears, "Reconciliation must never perform cleanup")
            assertFailsWith<PrivateStoreAccessDenied> { boundary.protect { drafts.data.first() } }
        }
        suspend fun close() {
            job.cancelAndJoin()
            dir.deleteRecursively()
        }
    }

    @Test(timeout = 15000)
    fun journalReadFailureRetryCannotPublishBeforeCountReset() = runBlocking {
        val f = Fixture()
        try {
            f.seed()
            val old = f.session.state.value
            f.jar.account = "B"
            f.faults.read = { throw IOException("injected read") }
            assertFailsWith<IOException> { f.boundary.reconcile() }
            assertEquals(old, f.session.state.value)
            assertTrue(f.publications.isEmpty())
            f.preserved()
            f.faults.read = {}
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            f.before = {
                entered.complete(Unit)
                release.await()
            }
            val retry = launch { f.boundary.reconcile() }
            try {
                withTimeout(2000) { selectRetryGate(entered, retry) }
                assertFalse(retry.isCompleted, "Retry skipped unfinished reconciliation")
                assertEquals(old, f.session.state.value)
                assertTrue(f.publications.isEmpty(), "Session must not publish with old counts")
            } finally {
                release.complete(Unit)
                retry.join()
            }
            assertEquals(listOf(0), f.publications)
            assertNotEquals(old, f.session.state.value)
            f.preserved()
            assertEquals(PrivateStorePhase.UNKNOWN, f.provenance.load().phase)
        } finally {
            f.close()
        }
    }

    @Test(timeout = 15000)
    fun cancelledMutationBeginCannotReuseCompletedOwnerShortcut() = runBlocking {
        cancelledBegin(external = false)
    }

    @Test(timeout = 15000)
    fun cancelledExternalBeginCannotReuseCompletedOwnerShortcut() = runBlocking {
        cancelledBegin(external = true)
    }

    private suspend fun cancelledBegin(external: Boolean) = coroutineScope {
        val f = Fixture()
        val release = CompletableDeferred<Unit>()
        var writer: Job? = null
        var mutation: Job? = null
        try {
            f.boundary.reconcile()
            f.seed()
            f.publications.clear()
            f.count = 9
            val epoch = f.boundary.state.value.identityEpoch
            val entered = CompletableDeferred<Unit>()
            val draining = CompletableDeferred<Unit>()
            writer = launch {
                f.boundary.protect {
                    entered.complete(Unit)
                    try {
                        awaitCancellation()
                    } finally {
                        withContext(NonCancellable) {
                            draining.complete(Unit)
                            release.await()
                            f.seed()
                        }
                    }
                }
            }
            withTimeout(2000) { entered.await() }
            var blockRan = false
            mutation = launch {
                if (external) {
                    f.boundary.beginExternalMutation()
                } else {
                    f.boundary.sessionMutation { blockRan = true }
                }
            }
            withTimeout(2000) { draining.await() }
            mutation.cancel()
            assertFalse(mutation.isCompleted, "Cancellation must still join old work")
            assertEquals(PrivateStorePhase.TRANSITIONING, f.provenance.load().phase)
            assertTrue(f.publications.isEmpty())
            release.complete(Unit)
            withTimeout(2000) {
                mutation.join()
                writer.join()
            }
            assertTrue(mutation.isCancelled)
            assertFalse(blockRan)
            assertTrue(f.publications.isEmpty())
            f.preserved()
            val countsEntered = CompletableDeferred<Unit>()
            val countsRelease = CompletableDeferred<Unit>()
            f.before = {
                countsEntered.complete(Unit)
                countsRelease.await()
            }
            val retry = launch { f.boundary.reconcile() }
            try {
                withTimeout(2000) { selectRetryGate(countsEntered, retry) }
                assertFalse(retry.isCompleted, "Cancelled begin must invalidate observed owner")
                assertTrue(f.publications.isEmpty(), "Counts must reset before retry publication")
            } finally {
                countsRelease.complete(Unit)
                retry.join()
            }
            assertEquals(listOf(0), f.publications)
            assertNotEquals(epoch, f.boundary.state.value.identityEpoch)
            f.preserved()
            f.boundary.reset(true, f.boundary.state.value.identityEpoch)
            assertEquals(PrivateStorePhase.READY, f.boundary.state.value.phase)
            assertNull(f.boundary.protect { f.drafts.data.first()[f.key] })
            assertEquals(1, f.clears)
        } finally {
            release.complete(Unit)
            mutation?.cancelAndJoin()
            writer?.cancelAndJoin()
            f.close()
        }
    }

    @Test(timeout = 15000)
    fun journalReadFailureRevokesAndJoinsExistingWork() = runBlocking {
        journalFailureJoins(readFailure = true)
    }

    @Test(timeout = 15000)
    fun journalWriteFailureRevokesAndJoinsExistingWork() = runBlocking {
        journalFailureJoins(readFailure = false)
    }

    private suspend fun journalFailureJoins(readFailure: Boolean) = coroutineScope {
        val f = Fixture()
        val release = CompletableDeferred<Unit>()
        var writer: Job? = null
        var transition: Deferred<Result<Unit>>? = null
        try {
            f.boundary.reconcile()
            f.seed()
            f.publications.clear()
            f.count = 9
            val old = f.session.state.value
            val entered = CompletableDeferred<Unit>()
            val draining = CompletableDeferred<Unit>()
            writer = launch {
                f.boundary.protect {
                    entered.complete(Unit)
                    try {
                        awaitCancellation()
                    } finally {
                        withContext(NonCancellable) {
                            draining.complete(Unit)
                            release.await()
                            f.seed()
                        }
                    }
                }
            }
            withTimeout(2000) { entered.await() }
            if (readFailure) {
                f.jar.account = "B"
                f.faults.read = { throw IOException("injected read") }
            } else {
                f.faults.write = { throw IOException("injected write") }
            }
            transition = async {
                runCatching {
                    if (readFailure) {
                        f.boundary.reconcile()
                    } else {
                        f.boundary.sessionMutation { error("Mutation must not run after journal failure") }
                    }
                }
            }
            withTimeout(2000) { selectRetryGate(draining, transition) }
            assertFalse(transition.isCompleted, "Journal failure must not abandon the old writer")
            assertNotEquals(PrivateStorePhase.READY, f.boundary.state.value.phase)
            assertEquals(old, f.session.state.value)
            assertTrue(f.publications.isEmpty())
            assertEquals(9, f.count, "Counts must not reset before old work terminates")
            release.complete(Unit)
            assertIs<IOException>(withTimeout(2000) { transition.await() }.exceptionOrNull())
            assertTrue(writer.isCompleted)
            f.preserved()
            f.faults.read = {}
            f.faults.write = {}
            f.boundary.reconcile()
            assertEquals(listOf(0), f.publications)
            assertEquals(0, f.clears)
            assertEquals("legacy private draft", f.drafts.data.first()[f.key])
        } finally {
            release.complete(Unit)
            transition?.cancelAndJoin()
            writer?.cancelAndJoin()
            f.close()
        }
    }

    @Test(timeout = 15000)
    fun mutationJournalCommitFailureRetryMustResetCounts() = runBlocking {
        failedCompletionRetry(reset = false, journalFailure = true)
    }

    @Test(timeout = 15000)
    fun mutationPublicationFailureRetryMustResetCounts() = runBlocking {
        failedCompletionRetry(reset = false, journalFailure = false)
    }

    @Test(timeout = 15000)
    fun resetPublicationFailureRetryMustResetCounts() = runBlocking {
        failedCompletionRetry(reset = true, journalFailure = false)
    }

    @Test(timeout = 15000)
    fun externalPublicationFailureDoesNotLatchCompletedBrowserMutation() = runBlocking {
        failedCompletionRetry(reset = false, journalFailure = false, external = true)
    }

    private suspend fun failedCompletionRetry(reset: Boolean, journalFailure: Boolean, external: Boolean = false) = coroutineScope {
        val f = Fixture()
        try {
            f.boundary.reconcile()
            f.seed()
            f.publications.clear()
            f.count = 9
            val old = f.session.state.value
            if (journalFailure) {
                var writes = 0
                f.faults.write = { if (++writes == 3) throw IOException("injected commit") }
            } else {
                f.publishing = { throw IOException("injected publication") }
            }
            assertFailsWith<IOException> {
                if (reset) {
                    f.boundary.reset(true, f.boundary.state.value.identityEpoch)
                } else if (external) {
                    f.boundary.beginExternalMutation()
                    f.boundary.finishExternalMutation()
                } else {
                    f.boundary.sessionMutation { }
                }
            }
            assertEquals(old, f.session.state.value)
            assertTrue(f.publications.isEmpty())
            assertNotEquals(PrivateStorePhase.READY, f.boundary.state.value.phase)
            assertFailsWith<PrivateStoreAccessDenied> { f.boundary.protect { "private" } }
            if (!reset) f.preserved()
            f.count = 9
            f.faults.write = {}
            f.publishing = {}
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            f.before = {
                entered.complete(Unit)
                release.await()
            }
            val retry = launch { f.boundary.reconcile() }
            try {
                withTimeout(2000) { selectRetryGate(entered, retry) }
                assertFalse(retry.isCompleted, "Failed completion must not cache observed owner")
                assertTrue(f.publications.isEmpty())
                assertEquals(old, f.session.state.value)
            } finally {
                release.complete(Unit)
                retry.join()
            }
            assertEquals(listOf(0), f.publications)
            assertEquals(if (reset) 1 else 0, f.clears)
            if (journalFailure) {
                assertEquals(PrivateStorePhase.TRANSITIONING, f.provenance.load().phase)
                f.preserved()
            } else {
                assertEquals(PrivateStorePhase.READY, f.boundary.state.value.phase)
            }
        } finally {
            f.close()
        }
    }

    @Test(timeout = 15000)
    fun unknownLegacyWriteAndCountFailuresRetryWithoutAdoptionOrCleanup() = runBlocking {
        for (stage in listOf("write", "counts", "publication")) {
            val f = Fixture()
            try {
                f.seed()
                val old = f.session.state.value
                f.jar.account = "B"
                when (stage) {
                    "write" -> f.faults.write = { throw IOException("injected unknown write") }
                    "counts" -> f.before = { throw IOException("injected count reset") }
                    else -> f.publishing = { throw IOException("injected publication") }
                }
                assertFailsWith<IOException> { f.boundary.reconcile() }
                assertEquals(old, f.session.state.value)
                assertTrue(f.publications.isEmpty())
                f.preserved()
                f.faults.write = {}
                f.before = {}
                f.publishing = {}
                f.count = 9
                f.boundary.reconcile()
                assertEquals(listOf(0), f.publications)
                assertEquals(PrivateStorePhase.UNKNOWN, f.provenance.load().phase)
                f.preserved()
                // A new production coordinator over the same real journal must not adopt legacy rows.
                val relaunched = PrivateSessionBoundary(
                    f.provenance,
                    f.session::privateOwnerProof,
                    listOf(PrivateStoreParticipant("draft", { f.drafts.data.first().asMap().isEmpty() }, { error("No cleanup") })),
                )
                relaunched.reconcile()
                assertFailsWith<PrivateStoreAccessDenied> { relaunched.protect { "legacy" } }
                f.preserved()
            } finally {
                f.close()
            }
        }
    }

    private suspend fun selectRetryGate(entered: CompletableDeferred<Unit>, retry: Job) {
        kotlinx.coroutines.selects.select<Unit> {
            entered.onAwait { }
            retry.onJoin { }
        }
    }
}
