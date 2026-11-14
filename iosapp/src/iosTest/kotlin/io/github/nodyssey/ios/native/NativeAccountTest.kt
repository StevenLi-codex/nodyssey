package io.github.nodyssey.ios.native

import kotlinx.coroutines.async
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class NativeAccountTest {
    @Test
    fun attendanceDoesNotExposePreviousAccountOrYesterday() {
        val status = io.github.nodyssey.data.AttendanceStatus(7, kotlinx.datetime.LocalDate(2026, 1, 1), true, 5)
        val owner = io.github.nodyssey.data.UserProfile(7, "owner", "avatar")
        val other = owner.copy(uid = 8)
        assertEquals(kotlinx.serialization.json.JsonNull, accountAttendanceDto(null, status, "2026-01-01"))
        assertEquals(kotlinx.serialization.json.JsonNull, accountAttendanceDto(other, status, "2026-01-01"))
        assertEquals(kotlinx.serialization.json.JsonNull, accountAttendanceDto(owner, status, "2026-01-02"))
        assertEquals(status.accountDto(), accountAttendanceDto(owner, status, "2026-01-01"))
    }

    @Test
    fun concurrentMutationIsRefusedRatherThanQueuedOrRetried(): Unit = kotlinx.coroutines.runBlocking {
        val gate = AccountMutationGate()
        val entered = kotlinx.coroutines.CompletableDeferred<Unit>()
        val release = kotlinx.coroutines.CompletableDeferred<Unit>()
        var calls = 0
        val first = kotlinx.coroutines.CoroutineScope(coroutineContext).async {
            gate.run {
                calls++
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()
        assertFailsWith<IllegalArgumentException> { gate.run { calls++ } }
        assertEquals(1, calls)
        release.complete(Unit)
        first.await()
        assertFailsWith<IllegalStateException> { gate.run { error("server refusal") } }
        gate.run { calls++ }
        assertEquals(2, calls)
    }

    @Test
    fun historyUndoCannotRestoreAnotherSessionAndIsSingleUse() {
        val undo = AccountHistoryUndo()
        val session = io.github.nodyssey.data.session.SessionState(true, true, 51, 4)
        val entry = io.github.nodyssey.data.ReadHistoryEntry(7, "private", null, null, null, null, 10)
        val id = undo.put(entry, session, 100)
        assertEquals(entry, undo.get(id, session, 101))
        assertFailsWith<IllegalArgumentException> { undo.get(id, session.copy(fingerprint = 52), 101) }
        val fresh = undo.put(entry, session, 100)
        undo.discard(fresh)
        assertFailsWith<IllegalArgumentException> { undo.get(fresh, session, 101) }
    }

    @Test
    fun collectionWalkStopsAtEmptyAndDeduplicatesMovingRows() = kotlinx.coroutines.runBlocking {
        val row = io.github.nodyssey.data.SpacePost(7, "title", null, null, null, null, null, null)
        val calls = mutableListOf<Int>()
        val result = accountCollectPages { page ->
            calls += page
            io.github.nodyssey.data.SpacePage(if (page < 3) listOf(row) else emptyList(), page, true)
        }
        assertEquals(listOf(1, 2, 3), calls)
        assertEquals(listOf(7L), result.posts.map { it.postId })
        assertEquals(false, result.truncated)
    }

    @Test
    fun collectionWalkReportsBoundAndPropagatesCancellation(): Unit = kotlinx.coroutines.runBlocking {
        val result = accountCollectPages { page ->
            io.github.nodyssey.data.SpacePage(listOf(io.github.nodyssey.data.SpacePost(page.toLong(), "title", null, null, null, null, null, null)), page, true)
        }
        assertEquals(20, result.posts.size)
        assertEquals(true, result.truncated)
        assertFailsWith<kotlinx.coroutines.CancellationException> {
            accountCollectPages { throw kotlinx.coroutines.CancellationException("cancelled") }
        }
    }

    @Test
    fun transferRejectsUnconfirmedOverflowAndZeroBeforeRepositoryCall() {
        val good = "{\"recipientUid\":9,\"amount\":2,\"refId\":0,\"onetime\":false,\"confirmed\":true}"
        for (raw in listOf(good.replace("\"amount\":2", "\"amount\":0"), good.replace("\"amount\":2", "\"amount\":2147483648"), good.replace("\"confirmed\":true", "\"confirmed\":false"))) {
            assertFailsWith<IllegalArgumentException> { (Json.parseToJsonElement(raw) as kotlinx.serialization.json.JsonObject).accountTransfer() }
        }
        val transfer = (Json.parseToJsonElement(good) as kotlinx.serialization.json.JsonObject).accountTransfer()
        assertEquals(0L, transfer.refId)
        assertEquals(2, transfer.amount)
    }

    @Test
    fun sessionDtoDoesNotExposeFingerprint() {
        val dto = io.github.nodyssey.data.session.SessionState(true, true, 1234567, 8).accountDto()
        assertEquals("{\"isSignedIn\":true,\"hasClearance\":true,\"generation\":8}", dto.toString())
    }

    @Test
    fun nullBalancesAndLargeIdentitySurviveMapping() {
        val dto = io.github.nodyssey.data.UserProfile(9007199254740993L, "name", "avatar").accountDto()
        assertEquals("9007199254740993", dto["uid"].toString())
        assertEquals(kotlinx.serialization.json.JsonNull, dto["chickenCount"])
    }

    @Test
    fun challengeCannotCrossSessionOrExpiry() {
        val store = AccountChallenges()
        val challenge = io.github.nodyssey.data.session.TwoFactorChallenge("reader", "never-export-this")
        val session = io.github.nodyssey.data.session.SessionState(true, true, 4, 7)
        val id = store.put(challenge, session, 100)
        assertEquals(challenge, store.get(id, session, 101))
        assertFailsWith<IllegalArgumentException> { store.get(id, session.copy(fingerprint = 5), 101) }
        val fresh = store.put(challenge, session, 100)
        assertFailsWith<IllegalArgumentException> { store.get(fresh, session, 300101) }
        val replaced = store.put(challenge, session, 100)
        store.put(challenge, session, 100)
        assertFailsWith<IllegalArgumentException> { store.get(replaced, session, 101) }
    }

    @Test
    fun confirmationCannotBeTruthyStringOrMissing() {
        for (raw in listOf("{}", "{\"confirmed\":false}", "{\"confirmed\":\"true\"}")) {
            assertFailsWith<IllegalArgumentException> { (Json.parseToJsonElement(raw) as kotlinx.serialization.json.JsonObject).accountConfirmed() }
        }
        (Json.parseToJsonElement("{\"confirmed\":true}") as kotlinx.serialization.json.JsonObject).accountConfirmed()
    }

    @Test
    fun identifiersNeverTruncateOrCoerceStrings() {
        val omittedPage = Json.parseToJsonElement("{\"page\":null}") as kotlinx.serialization.json.JsonObject
        assertEquals(1, omittedPage.accountPage())
        val args = Json.parseToJsonElement("{\"uid\":9007199254740993}") as kotlinx.serialization.json.JsonObject
        assertEquals(9007199254740993L, args.accountLong("uid"))
        for (raw in listOf("{\"uid\":1.2}", "{\"uid\":\"12\"}", "{\"uid\":0}", "{\"uid\":-1}", "{}")) {
            assertFailsWith<IllegalArgumentException> { (Json.parseToJsonElement(raw) as kotlinx.serialization.json.JsonObject).accountLong("uid") }
        }
    }
}
