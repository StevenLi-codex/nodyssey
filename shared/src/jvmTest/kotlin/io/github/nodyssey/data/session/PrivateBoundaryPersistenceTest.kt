package io.github.nodyssey.data.session

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.composer.DefaultPostComposerRepository
import io.github.nodyssey.data.composer.PostDraft
import io.github.plaza.core.AppClock
import io.github.plaza.core.AppDispatchers
import io.github.plaza.core.net.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okio.Path.Companion.toPath
import java.io.File
import kotlin.test.*

class PrivateBoundaryPersistenceTest {
    private class Jar : SessionCookieStore {
        var header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-a"
        override fun cookieHeader(url: String): String = header
        override fun setCookie(url: String, value: String) { error("No cookie writes") }
        override suspend fun removeAll() { header = "" }
        override fun flush() = Unit
    }

    @Test fun nestedLeaseAndCancelledTransitionJoinLateWriterBeforeCleanup() = runBlocking {
        val barrier = SessionWorkBarrier()
        barrier.open("A")
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val persisted = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val writer = launch {
            barrier.withLease("A") {
                barrier.withLease("A") {
                    entered.complete(Unit)
                    try { awaitCancellation() } finally {
                        withContext(NonCancellable) { release.await(); events += "late-A-write" }
                    }
                }
            }
        }
        withTimeout(2000) { entered.await() }
        val transition = launch {
            barrier.closeAndJoin { events += "journal"; persisted.complete(Unit) }
            events += "cleanup"
        }
        withTimeout(2000) { persisted.await() }
        transition.cancel()
        assertFalse(transition.isCompleted)
        assertFailsWith<PrivateStoreAccessDenied> { barrier.withLease("A") { error("Not admitted") } }
        release.complete(Unit)
        withTimeout(2000) { writer.join(); transition.join() }
        assertEquals(listOf("journal", "late-A-write"), events, "Cancelled cleanup must not commit trust")
    }

    @Test fun authProofIgnoresClearanceButNotCollidingAuthCookies() {
        val jar = Jar()
        val cookies = SessionCookies(NodeSeekSite.CONFIG, jar)
        val name = NodeSeekSite.CONFIG.sessionCookieNames.first()
        jar.header = "$name=Aa; cf_clearance=one"
        val a = cookies.privateOwnerProof()
        val fingerprint = cookies.snapshot().fingerprint
        jar.header = "$name=Aa; cf_clearance=two"
        assertEquals(a, cookies.privateOwnerProof())
        assertNotEquals(fingerprint, cookies.snapshot().fingerprint)
        jar.header = "$name=BB; cf_clearance=one"
        assertEquals(fingerprint, cookies.snapshot().fingerprint, "Fixture reproduces the 32-bit collision")
        assertNotEquals(a, cookies.privateOwnerProof())
        assertFalse(a.toString().contains("Aa"))
    }

    @Test fun boundaryRechecksOwnerBeforeProtectedCommit() = runBlocking {
        val dir = File(System.getProperty("java.io.tmpdir"), "recheck-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val job = SupervisorJob()
        val store = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { File(dir, "owner.preferences_pb").path.toPath() })
        val jar = Jar()
        var proof = SessionCookies(NodeSeekSite.CONFIG, jar).privateOwnerProof()
        val boundary = PrivateSessionBoundary(PrivateStoreProvenance(store, emptySet()), { proof }, emptyList())
        try {
            boundary.reconcile()
            assertEquals(PrivateStorePhase.READY, boundary.state.value.phase)
            proof = PrivateOwnerProof("different-proof")
            assertFailsWith<PrivateStoreAccessDenied> { boundary.protect { "private" } }
            Unit
        } finally { job.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun authPublicationIsDeferredUntilBoundaryAcknowledges() = runBlocking {
        val jar = Jar()
        val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
        val old = session.state.value
        jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=B"
        val snapshot = session.sync()
        assertNotEquals(old.fingerprint, snapshot.fingerprint)
        assertEquals(old, session.state.value)
        session.publishReconciled()
        assertEquals(snapshot.fingerprint, session.state.value.fingerprint)
    }

    @Test fun mutationFailureReconcilesWithoutDeletingAndClearanceKeepsEpoch() = runBlocking {
        val dir = File(System.getProperty("java.io.tmpdir"), "mutation-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val job = SupervisorJob()
        val store = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { File(dir, "owner.preferences_pb").path.toPath() })
        val jar = Jar()
        var count = 9
        val publications = mutableListOf<Int>()
        val boundary = PrivateSessionBoundary(PrivateStoreProvenance(store, emptySet()), { SessionCookies(NodeSeekSite.CONFIG, jar).privateOwnerProof() }, emptyList(), { count = 0 }, { publications += count })
        try {
            boundary.reconcile()
            val first = boundary.state.value.identityEpoch
            boundary.sessionMutation { jar.header += "; cf_clearance=new" }
            assertEquals(first, boundary.state.value.identityEpoch)
            count = 9
            assertFailsWith<IllegalArgumentException> {
                boundary.sessionMutation { jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=B"; throw IllegalArgumentException() }
            }
            assertEquals(0, publications.last())
            assertNotEquals(first, boundary.state.value.identityEpoch)
            assertEquals(PrivateStorePhase.UNKNOWN, boundary.state.value.phase)
        } finally { job.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun interruptedEmptyJournalNeverBecomesFreshOnRepeatedBootstrap() = runBlocking {
        val dir = File(System.getProperty("java.io.tmpdir"), "interrupted-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val job = SupervisorJob()
        val store = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { File(dir, "owner.preferences_pb").path.toPath() })
        val proof = SessionCookies(NodeSeekSite.CONFIG, Jar()).privateOwnerProof()
        val provenance = PrivateStoreProvenance(store, setOf("draft"))
        try {
            provenance.begin(proof, "interrupted")
            repeat(2) {
                val boundary = PrivateSessionBoundary(provenance, { proof }, listOf(PrivateStoreParticipant("draft", { true }, { error("Never delete") })))
                boundary.reconcile()
                assertNotEquals(PrivateStorePhase.READY, boundary.state.value.phase, "An interrupted journal is not a fresh install")
            }
        } finally { job.cancelAndJoin(); dir.deleteRecursively() }
    }

    @Test fun unknownDraftIsPreservedButDeniedAndSameVerifiedOwnerReopens() = runBlocking {
        val dir = File(System.getProperty("java.io.tmpdir"), "boundary-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val jar = Jar()
        var scopeJob = SupervisorJob()
        fun store(name: String) = PreferenceDataStoreFactory.createWithPath(
            scope = CoroutineScope(scopeJob + Dispatchers.Default), produceFile = { File(dir, "$name.preferences_pb").path.toPath() },
        )
        val transport = object : HttpTransport {
            override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse = error("No HTTP")
        }
        try {
            var draftStore = store("draft")
            val raw = DefaultPostComposerRepository(draftStore, transport, AppDispatchers(), AppClock.System)
            raw.saveDraft(PostDraft(title = "A legacy private draft"))
            var provenance = PrivateStoreProvenance(store("owner"), setOf("draft"))
            var boundary = PrivateSessionBoundary(
                provenance, { SessionCookies(NodeSeekSite.CONFIG, jar).privateOwnerProof() },
                listOf(PrivateStoreParticipant("draft", { draftStore.data.first().asMap().isEmpty() }, { raw.deleteDraft() })),
            )
            var protected = DefaultPostComposerRepository(draftStore, transport, AppDispatchers(), AppClock.System, boundary)
            boundary.reconcile()
            assertEquals(PrivateStorePhase.UNKNOWN, boundary.state.value.phase)
            assertFailsWith<PrivateStoreAccessDenied> { protected.draft.first() }
            assertEquals("A legacy private draft", raw.draft.first()?.title)
            boundary.reset(true, boundary.state.value.identityEpoch)
            protected.saveDraft(PostDraft(title = "A verified private draft"))
            scopeJob.cancelAndJoin()
            scopeJob = SupervisorJob()
            draftStore = store("draft")
            provenance = PrivateStoreProvenance(store("owner"), setOf("draft"))
            val reopenedRaw = DefaultPostComposerRepository(draftStore, transport, AppDispatchers(), AppClock.System)
            boundary = PrivateSessionBoundary(provenance, { SessionCookies(NodeSeekSite.CONFIG, jar).privateOwnerProof() }, listOf(
                PrivateStoreParticipant("draft", { draftStore.data.first().asMap().isEmpty() }, { reopenedRaw.deleteDraft() }),
            ))
            protected = DefaultPostComposerRepository(draftStore, transport, AppDispatchers(), AppClock.System, boundary)
            boundary.reconcile()
            assertEquals("A verified private draft", protected.draft.first()?.title)
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-b"
            assertFailsWith<PrivateStoreAccessDenied> { protected.draft.first() }
            assertEquals("A verified private draft", reopenedRaw.draft.first()?.title, "Mismatch must not delete")
            boundary.reconcile()
            boundary.reset(true, boundary.state.value.identityEpoch)
            assertNull(protected.draft.first(), "B must not inherit A")
        } finally {
            scopeJob.cancelAndJoin()
            dir.deleteRecursively()
        }
    }
}
