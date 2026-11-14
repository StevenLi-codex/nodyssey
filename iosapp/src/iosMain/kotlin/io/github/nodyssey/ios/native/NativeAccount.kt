package io.github.nodyssey.ios.native

import io.github.nodyssey.core.LuckyDraw
import io.github.nodyssey.core.LuckyDrawParams
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.StardustReceiveMarkup
import io.github.nodyssey.core.report.ReportComparison
import io.github.nodyssey.data.AttendanceMode
import io.github.nodyssey.data.account.AccountProfileFields
import io.github.nodyssey.data.account.AvatarUpload
import io.github.nodyssey.data.session.SignInCredentials
import io.github.nodyssey.data.session.SignInOutcome
import io.github.nodyssey.data.session.SignInRefusal
import io.github.nodyssey.data.settings.OPTIONAL_HOME_BOARD_SLUGS
import io.github.nodyssey.data.settings.ReportCompareEntry
import io.github.plaza.core.net.SiteError
import io.github.plaza.core.net.SiteException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlin.io.encoding.Base64
import kotlin.time.Instant

private val accountJson = Json { encodeDefaults = true }
private val accountChallenges = AccountChallenges()
private val accountHistoryUndo = AccountHistoryUndo()
private val accountAuthLock = Mutex()
private val accountMutationGate = AccountMutationGate()
private val accountCollectionGate = AccountMutationGate()
private var accountAuthRevision = 0L

/** No HTTP/parser/storage implementation here: every route delegates to the existing graph. */
internal suspend fun NativeContext.accountRequest(operation: String, args: JsonObject): JsonElement? = when (operation) {
    "session.snapshot" -> graph.sessionRepository.peek().accountDto()

    "session.sync" -> {
        accountChallenges.clear()
        accountAuthRevision++
        graph.sessionRepository.sync().accountDto()
    }

    "session.signIn" -> accountAuthenticate(args, secondFactor = false)

    "session.verifyTwoFactor" -> accountAuthenticate(args, secondFactor = true)

    "session.cancelSignIn" -> {
        accountAuthRevision++
        accountChallenges.clear()
        accountObject()
    }

    "session.signOut" -> accountMutationGate.run {
        args.accountConfirmed()
        check(accountAuthLock.tryLock()) { "Authentication already in progress" }
        try {
            accountAuthRevision++
            accountChallenges.clear()
            accountHistoryUndo.clear()
            accountCollectionGate.run { graph.accountSignOut.signOut() }
            graph.sessionRepository.state.value.accountDto()
        } finally {
            accountAuthLock.unlock()
        }
    }

    "profile.self" -> {
        accountRequireSession()
        val session = graph.sessionRepository.peek()
        if (args["refresh"]?.takeUnless { it == JsonNull }?.let { args.accountBool("refresh") } == true) {
            graph.profileRepository.refreshProfile(session.fingerprint)
        }
        graph.profileRepository.profile().accountDto()
    }

    "profile.user" -> graph.profileRepository.profile(args.accountLong("uid")).accountDto()

    "space.topics" -> graph.userSpaceRepository.topics(args.accountLong("uid"), args.accountPage()).accountDto { it.accountDto() }

    "space.comments" -> graph.userSpaceRepository.comments(args.accountLong("uid"), args.accountPage()).accountDto { it.accountDto() }

    "space.collections", "bookmarks.list" -> {
        accountRequireSession()
        graph.userSpaceRepository.collections(args.accountPage()).accountDto { it.accountDto() }
    }

    "bookmarks.snapshot" -> requireNotNull(accountObserve(operation, args)).first()

    "bookmarks.refresh" -> accountCollectionGate.run {
        accountRequireSession()
        val result = accountCollectPages(graph.userSpaceRepository::collections)
        graph.collectedPostMetaStore.rememberCollection(
            result.posts.map { post ->
                io.github.nodyssey.data.CollectedPostMeta(
                    postId = post.postId,
                    title = post.title,
                    categoryTitle = post.categoryTitle,
                    categorySlug = post.categorySlug,
                    authorName = post.authorName,
                    commentCount = post.commentCount,
                    createdAtText = post.createdAtText,
                )
            },
        )
        graph.offlineLibrary.noteReplyCounts(result.posts.mapNotNull { post -> post.commentCount?.let { post.postId to it } }.toMap())
        accountObject("truncated" to result.truncated, "items" to accountArray(graph.collectedPostMetaStore.observeCollection().first()) { it.accountDto() })
    }

    "social.following" -> {
        accountRequireSession()
        accountArray(graph.followRepository.following()) { it.accountDto() }
    }

    "social.followers" -> {
        accountRequireSession()
        accountArray(graph.followRepository.followers()) { it.accountDto() }
    }

    "social.follow" -> accountWrite {
        accountRequireSession()
        graph.followRepository.follow(args.accountLong("uid"))
    }

    "social.unfollow" -> accountWrite {
        accountRequireSession()
        graph.followRepository.unfollow(args.accountLong("uid"))
    }

    "social.block" -> accountWrite {
        args.accountConfirmed()
        accountRequireSession()
        graph.accountSettingsRepository.block(args.accountText("name"))
    }

    "social.unblock" -> accountWrite {
        args.accountConfirmed()
        accountRequireSession()
        graph.accountSettingsRepository.unblock(args.accountLong("uid"))
    }

    "account.blockedUsers" -> {
        accountRequireSession()
        accountArray(graph.accountSettingsRepository.blockedUsers()) { it.accountDto() }
    }

    "history.list", "tracked.list", "reports.list" -> requireNotNull(accountObserve(operation, args)).first()

    "history.remove" -> accountMutationGate.run {
        args.accountConfirmed()
        val id = args.accountLong("postId")
        val session = graph.sessionRepository.peek()
        val entry = graph.postRepository.readHistory().first().firstOrNull { it.postId == id }
        requireNotNull(entry) { "History entry no longer exists" }
        graph.postRepository.removeFromHistory(id)
        accountObject("undoId" to accountHistoryUndo.put(entry, session, graph.clock.nowMillis()))
    }

    "history.restore" -> accountWrite {
        val id = args.accountText("undoId")
        val entry = accountHistoryUndo.get(id, graph.sessionRepository.peek(), graph.clock.nowMillis())
        graph.postRepository.restoreToHistory(entry)
        accountHistoryUndo.discard(id)
    }

    "history.clear" -> accountWrite {
        args.accountConfirmed()
        accountHistoryUndo.clear()
        graph.postRepository.clearReadHistory()
    }

    "assets.growth" -> {
        accountRequireSession()
        graph.assetsRepository.growth().accountDto()
    }

    "assets.credit" -> {
        accountRequireSession()
        graph.creditRepository.page(args.accountPage()).let {
            accountObject(
                "items" to accountArray(it.entries) { row -> row.accountDto() },
                "page" to it.page,
                "totalPages" to it.totalPages,
                "hasNextPage" to it.hasNextPage,
            )
        }
    }

    "assets.stardust" -> {
        accountRequireSession()
        val memberId = args.accountOptionalLong("memberId") ?: accountSelfUid()
        graph.stardustRepository.entries(memberId, args.accountOptionalLong("beforeId")).let {
            accountObject("items" to accountArray(it.entries) { row -> row.accountDto() }, "cursor" to it.cursor, "hasMore" to it.hasMore)
        }
    }

    "assets.recipient" -> {
        val recipient = args.accountLong("recipientUid")
        accountObject("name" to graph.stardustRepository.recipientName(recipient, accountSelfUid()))
    }

    "assets.transfer" -> accountWrite {
        val transfer = args.accountTransfer()
        val viewer = accountSelfUid()
        require(transfer.recipientUid != viewer) { "Cannot transfer to self" }
        graph.stardustRepository.send(transfer.recipientUid, transfer.amount, transfer.refId, viewer, transfer.onetime)
    }

    "assets.receipts" -> {
        accountRequireSession()
        accountArray(graph.stardustRepository.receipts(args.accountLong("memberId"), args.accountLong("refId", 0), args.accountOptionalLong("peerId"))) { it.accountDto() }
    }

    "assets.receiveCode" -> {
        val amount = args.accountInt("amount")
        val refId = args.accountLong("refId", 0)
        val description = args.accountText("description", allowBlank = true)
        val onetime = args.accountBool("onetime")
        val member = accountSelfUid()
        accountObject(
            "memberId" to member,
            "refId" to refId,
            "marker" to StardustReceiveMarkup.marker(member, refId, amount, description, onetime),
        )
    }

    "attendance.status" -> graph.assetsRepository.refreshAttendanceStatus(accountSelfUid()).accountDto()

    "attendance.sign" -> accountMutationGate.run {
        args.accountConfirmed()
        accountRequireSession()
        val mode = AttendanceMode.entries.firstOrNull { it.name == args.accountText("mode") }
        requireNotNull(mode) { "Invalid attendance mode" }
        graph.assetsRepository.signInForToday(mode).accountDto()
    }

    "attendance.board" -> accountArray(graph.assetsRepository.attendanceBoard(args.accountPage())) { it.accountDto() }

    "community.memberCount" -> accountObject("memberCount" to graph.communityRepository.memberCount())

    "community.award" -> graph.awardRepository.page(args.accountPage()).let {
        accountObject(
            "items" to accountArray(it.posts) { post -> post.accountDto() },
            "page" to it.page,
            "totalPages" to it.totalPages,
            "hasNextPage" to it.hasNextPage,
        )
    }

    "community.ruling" -> graph.rulingRepository.records(args.accountPage()).let {
        accountObject("items" to accountArray(it.records) { row -> row.accountDto() }, "page" to it.page, "totalPages" to it.totalPages)
    }

    "community.lucky" -> accountObject(
        "url" to LuckyDraw.link(
            LuckyDrawParams(
                args.accountLong("postId"),
                args.accountLong("drawAtMillis"),
                args.accountInt("prizeCount", maximum = LuckyDraw.MAX_PRIZE_COUNT),
                args.accountInt("startFloor", 0),
                args.accountBool("dedupeFloors"),
            ),
        ),
    )

    "community.invite" -> {
        accountRequireSession()
        accountObject(
            "chickenCount" to graph.profileRepository.profile().chickenCount,
            "url" to NodeSeekSite.BASE_URL + NodeSeekSite.INVITE_PATH,
            "purchaseRequiresWeb" to true,
        )
    }

    "account.profileFields" -> {
        accountRequireSession()
        graph.accountSettingsRepository.profileFields().accountDto()
    }

    "account.saveProfileFields" -> accountWrite {
        accountRequireSession()
        graph.accountSettingsRepository.saveProfileFields(
            AccountProfileFields(
                args.accountText("bio", true),
                args.accountText("signature", true),
                args.accountText("readme", true),
            ),
        )
    }

    "account.uploadAvatar" -> accountWrite {
        args.accountConfirmed()
        accountRequireSession()
        val encoded = args.accountText("base64")
        require(encoded.length <= 8_388_608) { "Avatar too large" }
        val mime = args.accountText("mimeType")
        require(mime in setOf("image/jpeg", "image/png", "image/gif")) { "Unsupported avatar type" }
        val bytes = Base64.decode(encoded)
        require(bytes.isNotEmpty() && bytes.size <= 6_291_456) { "Invalid avatar size" }
        graph.accountSettingsRepository.uploadAvatar(AvatarUpload(bytes, mime))
    }

    "account.changePassword" -> accountWrite {
        args.accountConfirmed()
        accountRequireSession()
        graph.accountSettingsRepository.changePassword(args.accountText("currentPassword"), args.accountText("newPassword"))
        accountChallenges.clear()
    }

    "account.twoFactor" -> {
        accountRequireSession()
        graph.accountSettingsRepository.twoFactor().accountDto()
    }

    "account.beginTwoFactor" -> accountMutationGate.run {
        args.accountConfirmed()
        accountRequireSession()
        accountObject("uri" to graph.accountSettingsRepository.beginTwoFactorEnrolment(args.accountText("password")))
    }

    "account.contact" -> {
        accountRequireSession()
        graph.accountSettingsRepository.contact().accountDto()
    }

    "account.telegram" -> {
        accountRequireSession()
        graph.accountSettingsRepository.telegramBinding().accountDto()
    }

    "account.unbindTelegram" -> accountWrite {
        args.accountConfirmed()
        accountRequireSession()
        graph.accountSettingsRepository.unbindTelegram()
    }

    "account.preferences" -> {
        accountRequireSession()
        val preferences = graph.accountSettingsRepository.remotePreferences()
        graph.settingsRepository.setHolidayTheme(preferences.holidayTheme)
        for (slug in OPTIONAL_HOME_BOARD_SLUGS) graph.settingsRepository.setHomeBoardHidden(slug, slug in preferences.hiddenBoards)
        preferences.accountDto()
    }

    "account.holidayTheme" -> accountWrite {
        accountRequireSession()
        val enabled = args.accountBool("enabled")
        graph.accountSettingsRepository.setHolidayTheme(enabled)
        graph.settingsRepository.setHolidayTheme(enabled)
    }

    "account.homeBoard" -> accountWrite {
        accountRequireSession()
        val slug = args.accountText("slug")
        require(slug in OPTIONAL_HOME_BOARD_SLUGS) { "Unsupported home board" }
        val hidden = args.accountBool("hidden")
        graph.accountSettingsRepository.setHomeBoardHidden(slug, hidden)
        graph.settingsRepository.setHomeBoardHidden(slug, hidden)
    }

    "reports.compare" -> {
        val requested = requireNotNull(args["entries"] as? JsonArray) { "Missing report selection" }.map(::accountReportArgument)
        require(requested.size in 2..3 && requested.distinct().size == requested.size) { "Select two or three distinct reports" }
        val stored = graph.reportCompareStore.entries.first()
        require(requested.all { wanted -> stored.any { it.isSameAs(wanted) } }) { "Report selection is stale" }
        ReportComparison.of(requested.map { it.report }).accountDto()
    }

    else -> null
}

@OptIn(ExperimentalCoroutinesApi::class)
internal fun NativeContext.accountObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when (operation) {
    "session.state" -> graph.sessionRepository.state.map { it.accountDto() }

    "profile.self" -> graph.sessionRepository.state.flatMapLatest { session ->
        if (!session.isSignedIn) {
            flowOf(JsonNull)
        } else {
            graph.profileRepository.observeProfile(session.fingerprint).map { it?.accountDto() ?: JsonNull }
        }
    }

    "attendance.status" -> graph.sessionRepository.state.flatMapLatest { session ->
        if (!session.isSignedIn) {
            flowOf(JsonNull)
        } else {
            combine(graph.profileRepository.observeProfile(session.fingerprint), graph.assetsRepository.observeAttendanceStatus()) { profile, status ->
                val today = Instant.fromEpochMilliseconds(graph.clock.nowMillis()).toLocalDateTime(TimeZone.of("Asia/Shanghai")).date.toString()
                accountAttendanceDto(profile, status, today)
            }
        }
    }

    "bookmarks.snapshot" -> graph.sessionRepository.state.flatMapLatest { session ->
        if (!session.isSignedIn) {
            flowOf(JsonArray(emptyList()))
        } else {
            graph.collectedPostMetaStore.observeCollection().map { accountArray(it) { row -> row.accountDto() } }
        }
    }

    "history.list" -> graph.postRepository.readHistory().map { accountArray(it) { row -> row.accountDto() } }

    "tracked.list" -> graph.trackedThreadStore.tracked.map { accountArray(it) { row -> row.accountDto() } }

    "reports.list" -> graph.reportCompareStore.entries.map { accountArray(it) { row -> accountJson.encodeToJsonElement(ReportCompareEntry.serializer(), row) } }

    else -> null
}

private fun NativeContext.accountRequireSession() {
    if (!graph.sessionRepository.peek().isSignedIn) throw SiteException(SiteError.LoginRequired)
}

private suspend fun NativeContext.accountSelfUid(): Long {
    accountRequireSession()
    return graph.profileRepository.profile().uid
}

private suspend fun accountWrite(block: suspend () -> Unit): JsonObject = accountMutationGate.run {
    block()
    accountObject()
}

private fun accountReportArgument(value: JsonElement?): ReportCompareEntry =
    accountJson.decodeFromJsonElement(ReportCompareEntry.serializer(), requireNotNull(value as? JsonObject) { "Missing report entry" })

private suspend fun NativeContext.accountAuthenticate(args: JsonObject, secondFactor: Boolean): JsonElement {
    check(accountAuthLock.tryLock()) { "Authentication already in progress" }
    val revision = ++accountAuthRevision
    try {
        val session = graph.sessionRepository.peek()
        val outcome = if (secondFactor) {
            val code = args.accountText("code")
            require(code.length == 6 && code.all { it in '0'..'9' }) { "Invalid authentication code" }
            val challenge = accountChallenges.get(args.accountText("challengeId"), session, graph.clock.nowMillis())
            graph.signInRepository.verifyTwoFactor(challenge, code)
        } else {
            accountChallenges.clear()
            graph.signInRepository.signIn(SignInCredentials(args.accountText("account"), args.accountText("password"), args.accountText("verificationToken")))
        }
        currentCoroutineContext().ensureActive()
        if (revision != accountAuthRevision) throw CancellationException("Sign-in superseded")
        return when (outcome) {
            SignInOutcome.Signed -> {
                accountChallenges.clear()
                val signed = graph.sessionRepository.syncAwaitingSession()
                if (!signed.isSignedIn) throw SiteException(SiteError.SessionUnrecognised)
                accountObject("status" to "SIGNED", "session" to signed.accountDto())
            }

            is SignInOutcome.TwoFactorRequired -> {
                val id = accountChallenges.put(outcome.challenge, session, graph.clock.nowMillis())
                accountObject("status" to "TWO_FACTOR_REQUIRED", "challengeId" to id, "account" to outcome.challenge.account)
            }

            is SignInOutcome.Refused -> {
                if (outcome.reason == SignInRefusal.TwoFactorSessionExpired) accountChallenges.clear()
                accountObject("status" to "REFUSED", "reason" to outcome.reason.name)
            }
        }
    } catch (cancelled: CancellationException) {
        accountChallenges.clear()
        throw cancelled
    } finally {
        accountAuthLock.unlock()
    }
}
