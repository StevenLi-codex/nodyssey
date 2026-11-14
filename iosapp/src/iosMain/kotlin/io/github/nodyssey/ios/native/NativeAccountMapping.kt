package io.github.nodyssey.ios.native

import io.github.nodyssey.data.UserProfile
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.data.session.TwoFactorChallenge
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import kotlin.uuid.Uuid

// Validation deliberately never interpolates input values into error messages.
internal fun JsonObject.accountText(key: String, allowBlank: Boolean = false): String {
    val value = this[key] as? JsonPrimitive
    require(value != null && value.isString) { "Missing or invalid argument: $key" }
    return value.content.also { require(allowBlank || it.isNotBlank()) { "Missing argument: $key" } }
}

internal fun JsonObject.accountOptionalText(key: String): String? =
    if (this[key] == null || this[key] == JsonNull) null else accountText(key, allowBlank = true)

internal fun JsonObject.accountLong(key: String, minimum: Long = 1): Long {
    val value = this[key] as? JsonPrimitive
    val number = value?.takeUnless { it.isString }?.longOrNull
    require(number != null && number >= minimum) { "Missing or invalid integer: $key" }
    return number
}

internal fun JsonObject.accountOptionalLong(key: String, minimum: Long = 1): Long? =
    if (this[key] == null || this[key] == JsonNull) null else accountLong(key, minimum)

internal fun JsonObject.accountInt(key: String, minimum: Int = 1, maximum: Int = Int.MAX_VALUE): Int {
    val value = accountLong(key, minimum.toLong())
    require(value <= maximum) { "Integer out of range: $key" }
    return value.toInt()
}

internal fun JsonObject.accountPage(): Int = if (this["page"] == null || this["page"] == JsonNull) 1 else accountInt("page")

internal fun JsonObject.accountBool(key: String): Boolean {
    val value = this[key] as? JsonPrimitive
    return requireNotNull(value?.takeUnless { it.isString }?.booleanOrNull) { "Missing or invalid boolean: $key" }
}

internal fun JsonObject.accountConfirmed() {
    require(accountBool("confirmed")) { "Explicit confirmation required" }
}

/** Refuse a concurrent mutation instead of queuing a duplicate purchase behind the first. */
internal class AccountMutationGate {
    private val lock = kotlinx.coroutines.sync.Mutex()

    suspend fun <T> run(block: suspend () -> T): T {
        require(lock.tryLock()) { "Another account action is in progress" }
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }
}

internal data class AccountTransfer(val recipientUid: Long, val amount: Int, val refId: Long, val onetime: Boolean)

internal fun JsonObject.accountTransfer(): AccountTransfer {
    accountConfirmed()
    return AccountTransfer(accountLong("recipientUid"), accountInt("amount"), accountLong("refId", 0), accountBool("onetime"))
}

internal data class AccountCollectionWalk(val posts: List<io.github.nodyssey.data.SpacePost>, val truncated: Boolean)

/** All pages are read before writing the local collection, so failures retain the previous list. */
internal suspend fun accountCollectPages(load: suspend (Int) -> io.github.nodyssey.data.SpacePage<io.github.nodyssey.data.SpacePost>): AccountCollectionWalk {
    val posts = linkedMapOf<Long, io.github.nodyssey.data.SpacePost>()
    for (page in 1..20) {
        val result = load(page)
        result.items.forEach { posts[it.postId] = it }
        if (!result.hasNextPage || result.items.isEmpty()) return AccountCollectionWalk(posts.values.toList(), false)
    }
    return AccountCollectionWalk(posts.values.toList(), true)
}

internal fun io.github.nodyssey.data.CollectedPostMeta.accountDto(): JsonObject = accountObject(
    "postId" to postId, "title" to title, "categoryTitle" to categoryTitle, "categorySlug" to categorySlug,
    "authorName" to authorName, "avatarUrl" to avatarUrl, "resolvedAvatarUrl" to resolvedAvatarUrl,
    "authorUid" to authorUid, "commentCount" to commentCount, "createdAtText" to createdAtText,
)

// Domain DTO mappings

internal fun io.github.nodyssey.data.SpacePost.accountDto(): JsonObject = accountObject(
    "postId" to postId,
    "title" to title,
    "categoryTitle" to categoryTitle,
    "categorySlug" to categorySlug,
    "authorName" to authorName,
    "commentCount" to commentCount,
    "viewCount" to viewCount,
    "createdAtText" to createdAtText,
    "permission" to permission.wireValue,
)

internal fun io.github.nodyssey.data.SpaceComment.accountDto(): JsonObject = accountObject(
    "postId" to postId,
    "commentId" to commentId,
    "postTitle" to postTitle,
    "excerpt" to excerpt,
    "createdAtText" to createdAtText,
    "floor" to floor,
)

internal fun io.github.nodyssey.data.FollowUser.accountDto(): JsonObject = accountObject(
    "uid" to uid,
    "name" to name,
    "avatarUrl" to avatarUrl,
)

internal fun io.github.nodyssey.data.account.BlockedUser.accountDto(): JsonObject = accountObject(
    "uid" to uid,
    "name" to name,
    "avatarUrl" to avatarUrl,
)

internal fun io.github.nodyssey.data.DailyQuota.accountDto(): JsonObject = accountObject(
    "used" to used,
    "total" to total,
)

internal fun io.github.nodyssey.core.LevelSpan.accountDto(): JsonObject = accountObject(
    "barRank" to barRank,
    "floor" to floor,
    "next" to next,
)

internal fun io.github.nodyssey.data.GrowthSnapshot.accountDto(): JsonObject = accountObject(
    "level" to level,
    "chickenCount" to chickenCount,
    "starCount" to starCount,
    "levelSpan" to levelSpan?.accountDto(),
    "postQuota" to postQuota.accountDto(),
    "commentQuota" to commentQuota.accountDto(),
    "attendanceQuota" to attendanceQuota.accountDto(),
    "feedingQuota" to feedingQuota.accountDto(),
)

internal fun io.github.nodyssey.data.AttendanceResult.accountDto(): JsonObject = accountObject(
    "gain" to gain,
    "message" to message,
)

internal fun accountAttendanceDto(profile: UserProfile?, status: io.github.nodyssey.data.AttendanceStatus?, today: String): JsonElement =
    if (profile != null && status != null && profile.uid == status.uid && status.date.toString() == today) status.accountDto() else JsonNull

internal fun io.github.nodyssey.data.AttendanceStatus.accountDto(): JsonObject = accountObject(
    "uid" to uid,
    "date" to date.toString(),
    "hasSignedIn" to hasSignedIn,
    "gain" to gain,
)

internal fun io.github.nodyssey.data.AttendanceBoardEntry.accountDto(): JsonObject = accountObject(
    "uid" to uid,
    "name" to name,
    "gain" to gain,
    "timeText" to timeText,
)

internal fun io.github.nodyssey.data.CreditEntry.accountDto(): JsonObject = accountObject(
    "change" to change,
    "balanceAfter" to balanceAfter,
    "reason" to reason,
    "createdAtMillis" to createdAtMillis,
)

internal fun io.github.nodyssey.data.StardustEntry.accountDto(): JsonObject = accountObject(
    "id" to id,
    "type" to type.name,
    "rawType" to rawType,
    "diff" to diff,
    "balanceAfter" to balanceAfter,
    "peerUid" to peerUid,
    "commentId" to commentId,
    "refId" to refId,
    "createdAtMillis" to createdAtMillis,
)

internal fun io.github.nodyssey.data.account.AccountProfileFields.accountDto(): JsonObject = accountObject(
    "bio" to bio,
    "signature" to signature,
    "readme" to readme,
)

internal fun io.github.nodyssey.data.account.AccountContact.accountDto(): JsonObject = accountObject(
    "email" to email,
    "emailVerified" to emailVerified,
)

internal fun io.github.nodyssey.data.account.TelegramBinding.accountDto(): JsonObject = accountObject(
    "bound" to bound,
    "displayName" to displayName,
    "avatarUrl" to avatarUrl,
)

internal fun io.github.nodyssey.data.account.TwoFactorState.accountDto(): JsonObject = accountObject(
    "enabled" to enabled,
)

internal fun io.github.nodyssey.data.TrackedThread.accountDto(): JsonObject = accountObject(
    "postId" to postId,
    "title" to title,
    "lastKnownCount" to lastKnownCount,
    "authorName" to authorName,
    "categoryTitle" to categoryTitle,
    "categorySlug" to categorySlug,
)

internal fun io.github.nodyssey.data.ReadingPosition.accountDto(): JsonObject = accountObject(
    "page" to page,
    "floor" to floor,
)

internal fun io.github.nodyssey.data.ReadHistoryEntry.accountDto(): JsonObject = accountObject(
    "postId" to postId,
    "title" to title,
    "authorName" to authorName,
    "authorUid" to authorUid,
    "categoryTitle" to categoryTitle,
    "commentCount" to commentCount,
    "lastReadAtMillis" to lastReadAtMillis,
    "readingPosition" to readingPosition?.accountDto(),
)

internal fun io.github.nodyssey.model.PostSummary.accountDto(): JsonObject = accountObject(
    "postId" to postId,
    "title" to title,
    "authorName" to authorName,
    "authorUid" to authorUid,
    "avatarUrl" to avatarUrl,
    "categoryTitle" to categoryTitle,
    "categorySlug" to categorySlug,
    "viewCount" to viewCount,
    "commentCount" to commentCount,
    "lastActiveText" to lastActiveText,
    "lastActiveTitle" to lastActiveTitle,
    "lastCommenterName" to lastCommenterName,
    "isPinned" to isPinned,
    "isLocked" to isLocked,
    "isAwarded" to isAwarded,
    "lockLevel" to lockLevel,
    "isBlocked" to isBlocked,
)

internal fun <T> io.github.nodyssey.data.SpacePage<T>.accountDto(map: (T) -> JsonElement): JsonObject = accountObject(
    "items" to accountArray(items, map),
    "page" to page,
    "hasNextPage" to hasNextPage,
)

internal fun io.github.nodyssey.data.account.RemoteAccountPreferences.accountDto(): JsonObject = accountObject(
    "holidayTheme" to holidayTheme,
    "hiddenBoards" to accountArray(hiddenBoards.sorted(), ::JsonPrimitive),
)

internal fun io.github.nodyssey.data.RulingRecord.accountDto(): JsonObject = accountObject(
    "id" to id, "targetName" to targetName, "targetUid" to targetUid, "target" to target.name,
    "postId" to postId, "floor" to floor, "reason" to reason,
    "actions" to accountArray(actions) { it.accountDto() }, "moderatorName" to moderatorName,
    "createdAtMillis" to createdAtMillis, "kind" to kind.name,
)

internal fun io.github.nodyssey.data.RulingAction.accountDto(): JsonObject = when (this) {
    is io.github.nodyssey.data.RulingAction.Coin -> accountObject("type" to "Coin", "diff" to diff)
    is io.github.nodyssey.data.RulingAction.Stardust -> accountObject("type" to "Stardust", "diff" to diff)
    is io.github.nodyssey.data.RulingAction.Title -> accountObject("type" to "Title", "title" to title)
    is io.github.nodyssey.data.RulingAction.Move -> accountObject("type" to "Move", "boardSlug" to boardSlug)
    is io.github.nodyssey.data.RulingAction.ReadRank -> accountObject("type" to "ReadRank", "rank" to rank)
    is io.github.nodyssey.data.RulingAction.Lock -> accountObject("type" to "Lock", "locked" to locked)
    is io.github.nodyssey.data.RulingAction.Award -> accountObject("type" to "Award", "award" to award)
    is io.github.nodyssey.data.RulingAction.Hide -> accountObject("type" to "Hide", "hidden" to hidden, "wholeUser" to wholeUser)
    is io.github.nodyssey.data.RulingAction.Pin -> accountObject("type" to "Pin", "pinned" to pinned)
    is io.github.nodyssey.data.RulingAction.Suspend -> accountObject("type" to "Suspend", "days" to days)
}

internal fun io.github.nodyssey.core.report.ReportComparison.accountDto(): JsonObject = accountObject(
    "reportCount" to reportCount,
    "sections" to accountArray(sections) { section ->
        accountObject(
            "title" to section.title,
            "rows" to accountArray(section.rows) { row ->
                accountObject(
                    "label" to row.label,
                    "cells" to accountArray(row.cells) { cell ->
                        cell?.let { accountArray(it) { value -> accountObject("text" to value.text, "tone" to value.tone.name) } } ?: JsonNull
                    },
                )
            },
        )
    },
)

internal fun accountObject(vararg fields: Pair<String, Any?>): JsonObject =
    JsonObject(fields.associate { (key, value) -> key to accountValue(value) })

// Only JSON primitives are accepted. Models must have an explicit mapping below.
internal fun accountValue(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Long -> JsonPrimitive(value)
    is Int -> JsonPrimitive(value)
    else -> error("Unsupported account DTO value")
}

internal fun <T> accountArray(items: Iterable<T>, map: (T) -> JsonElement): JsonArray = JsonArray(items.map(map))

internal fun SessionState.accountDto(): JsonObject = accountObject(
    "isSignedIn" to isSignedIn,
    "hasClearance" to hasClearance,
    "generation" to generation,
)

internal fun UserProfile.accountDto(): JsonObject = accountObject(
    "uid" to uid, "name" to name, "avatarUrl" to avatarUrl,
    "rank" to rank, "createdAt" to createdAt, "chickenCount" to chickenCount,
    "starCount" to starCount, "streakDays" to streakDays, "bio" to bio,
    "readme" to readme, "topicCount" to topicCount, "commentCount" to commentCount,
    "followed" to followed,
)

/** Session-bound transient undo receipts; Swift cannot inject old-account history into a new one. */
internal class AccountHistoryUndo {
    private data class Receipt(val entry: io.github.nodyssey.data.ReadHistoryEntry, val session: SessionState, val expiresAt: Long)
    private val receipts = linkedMapOf<String, Receipt>()

    fun clear() = receipts.clear()

    fun put(entry: io.github.nodyssey.data.ReadHistoryEntry, session: SessionState, now: Long): String {
        receipts.entries.removeAll { it.value.expiresAt <= now || it.value.session != session }
        while (receipts.size >= 20) receipts.remove(receipts.keys.first())
        val id = Uuid.random().toString()
        receipts[id] = Receipt(entry, session, now + 300_000L)
        return id
    }

    fun get(id: String, session: SessionState, now: Long): io.github.nodyssey.data.ReadHistoryEntry {
        val receipt = receipts[id]
        if (receipt == null || receipt.session != session || receipt.expiresAt <= now) {
            receipts.remove(id)
            throw IllegalArgumentException("History undo expired")
        }
        return receipt.entry
    }

    fun discard(id: String) {
        receipts.remove(id)
    }
}

/** Main-dispatcher confined; the opaque handle never contains the site's OTP session. */
internal class AccountChallenges {
    private var handle: String? = null
    private var challenge: TwoFactorChallenge? = null
    private var session: SessionState? = null
    private var expiresAt = 0L

    fun clear() {
        handle = null
        challenge = null
        session = null
        expiresAt = 0L
    }

    fun put(value: TwoFactorChallenge, currentSession: SessionState, nowMillis: Long): String {
        clear()
        val id = Uuid.random().toString()
        handle = id
        challenge = value
        session = currentSession
        expiresAt = nowMillis + 300_000L
        return id
    }

    fun get(id: String, currentSession: SessionState, nowMillis: Long): TwoFactorChallenge {
        if (currentSession != session || nowMillis >= expiresAt) clear()
        require(id == handle && challenge != null) { "Sign-in challenge expired" }
        return requireNotNull(challenge)
    }
}
