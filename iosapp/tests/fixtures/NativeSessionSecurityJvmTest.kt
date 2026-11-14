package io.github.nodyssey.ios.native

import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.PostRepository
import io.github.nodyssey.data.NotificationRepository
import io.github.nodyssey.data.NotificationCounts
import io.github.nodyssey.data.OfflineLibrary
import io.github.nodyssey.data.ProfileRepository
import io.github.nodyssey.data.composer.PostComposerRepository
import io.github.nodyssey.data.composer.CommentComposerRepository
import io.github.nodyssey.data.settings.SettingsRepository
import io.github.nodyssey.core.net.JsonApi
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import okio.Path.Companion.toPath
import io.github.nodyssey.data.session.*
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.AppClock
import io.github.plaza.core.net.*
import java.lang.reflect.Proxy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import org.junit.Test
import kotlin.test.*

/** JVM integration fixture, not an Apple cookie-store simulation. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativeSessionSecurityJvmTest {
    private suspend fun NativeRequest.awaitFinished() {
        val field = NativeRequest::class.java.getDeclaredField("job").apply { isAccessible = true }
        withTimeout(2_000) { (field.get(this@awaitFinished) as Job).join() }
    }

    private class Jar : SessionCookieStore {
        var header = ""
        override fun cookieHeader(url: String): String = header
        override fun setCookie(url: String, cookie: String) { header = cookie.substringBefore(';') }
        override suspend fun removeAll() { header = "" }
        override fun flush() = Unit
    }

    private fun postRepository(): PostRepository = Proxy.newProxyInstance(
        PostRepository::class.java.classLoader, arrayOf(PostRepository::class.java),
    ) { _, method, _ ->
        when (method.name) {
            "reconcileSession" -> false
            "invalidateCaches", "clearSessionData" -> Unit
            else -> error("Unexpected repository method: ${method.name}")
        }
    } as PostRepository

    private inline fun <reified T> fixture(crossinline answer: (String) -> Any?): T = Proxy.newProxyInstance(
        T::class.java.classLoader, arrayOf(T::class.java),
    ) { _, method, _ -> answer(method.name) } as T

    private fun notifications() = NotificationRepository(fixture<JsonApi> { name ->
        check(name == "getJson")
        """{"reply":9,"atMe":4,"message":3}"""
    })

    @Test
    fun explicitSignOutResetsCountsEvenAfterPostMarkerWasCleared() = countsAfterTransition(signOut = true)

    @Test
    fun directAccountSwitchResetsCountsWithoutRefresh() = countsAfterTransition(signOut = false)

    @Test
    fun signOutRemovesDefaultBrowserAuthBeforeSuccess() = countsAfterTransition(signOut = true, browserCookies = true)

    @Test
    fun cancellingSignOutDuringCookieDeletionKeepsLeaseAndFinishesCleanup() = countsAfterTransition(signOut = true, browserCookies = true, cancelDuringDelete = true)

    @Test
    fun liveBrowserMustCloseBeforeSignOutCanDeleteCookies() = countsAfterTransition(signOut = true, browserCookies = true, liveBrowser = true)

    fun signedOutPublicationWhileReconciliationSuspendsRegression() = countsAfterTransition(signOut = true, delayReconcile = true)

    private fun countsAfterTransition(signOut: Boolean, browserCookies: Boolean = false, cancelDuringDelete: Boolean = false, liveBrowser: Boolean = false, delayReconcile: Boolean = false) = runBlocking {
        Dispatchers.setMain(Dispatchers.Unconfined)
        val storeJob = SupervisorJob()
        val file = java.io.File(System.getProperty("java.io.tmpdir"), "counts-${java.util.UUID.randomUUID()}.preferences_pb")
        var stateWatcher: Job? = null
        val requests = mutableListOf<NativeRequest>()
        val browserStore = platform.WebKit.WKWebsiteDataStore.defaultDataStore().httpCookieStore
        browserStore.jar.clear()
        browserStore.delayDelete = false
        browserStore.holdDelete = null
        try {
            val jar = Jar().apply { header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-a" }
            val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
            val counts = notifications()
            val posts = if (delayReconcile) object : PostRepository by postRepository() {
                override suspend fun reconcileSession(isSignedIn: Boolean, fingerprint: Int): Boolean {
                    if (!isSignedIn) delay(50)
                    return false
                }
            } else postRepository()
            val settings = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(storeJob + Dispatchers.Default), produceFile = { file.path.toPath() }))
            val cleanup = DefaultAccountSignOut(
                posts,
                fixture<ProfileRepository> { check(it == "clearCachedProfile"); Unit },
                fixture<OfflineLibrary> { check(it == "clearAll"); Unit },
                fixture<PostComposerRepository> { check(it == "deleteDraft"); Unit },
                fixture<CommentComposerRepository> { check(it == "deleteAllDrafts"); Unit },
                settings,
                session,
            )
            NodysseyApp.fixture = IosAppContainer(mapOf("sessionRepository" to session, "postRepository" to posts, "notificationRepository" to counts, "accountSignOut" to cleanup))
            suspend fun request(op: String, args: String = "{}"): String {
                val result = CompletableDeferred<String>()
                val request = NativeBridge.request(op, args) { result.complete(it) }
                requests += request
                val reply = withTimeout(2_000) { result.await() }
                request.awaitFinished()
                return reply
            }
            assertTrue(request("session.snapshot").contains("\"ok\":true"))
            counts.refreshCounts()
            assertEquals(16, counts.counts.value.all)
            val publishedCounts = CompletableDeferred<NotificationCounts>()
            stateWatcher = CoroutineScope(Dispatchers.Unconfined).launch {
                session.state.collect { if (!it.isSignedIn) publishedCounts.complete(counts.counts.value) }
            }
            val authName = NodeSeekSite.CONFIG.sessionCookieNames.first()
            val host = WebUrl.parse(NodeSeekSite.CONFIG.baseUrl)!!.host!!
            if (browserCookies) {
                browserStore.jar += platform.Foundation.NSHTTPCookie(authName, "browser-fixture", ".$host")
                browserStore.jar += platform.Foundation.NSHTTPCookie(authName, "unrelated-fixture", "unrelated.example")
            }
            if (liveBrowser) {
                val owner = NativeBrowserSession(browserStore, "login")
                assertTrue(NativePlatform.claim(owner))
                try {
                    assertTrue(request("session.signOut", "{\"confirmed\":true}").contains("BROWSER_BUSY"))
                    assertTrue(session.state.value.isSignedIn)
                    assertTrue(browserStore.jar.any { it.domain == ".$host" })
                } finally {
                    NativePlatform.release(owner)
                    browserStore.jar.clear()
                }
                return@runBlocking
            }
            if (signOut) {
                if (cancelDuringDelete) {
                    browserStore.delayDelete = true
                    val replies = mutableListOf<String>()
                    val request = NativeBridge.request("session.signOut", "{\"confirmed\":true}", replies::add)
                    requests += request
                    assertNotNull(browserStore.holdDelete)
                    request.cancel()
                    assertTrue(session.state.value.isSignedIn, "Signed-out must not publish before WebKit deletion callback")
                    val competing = NativeBrowserSession(browserStore, "login")
                    assertFalse(NativePlatform.claim(competing), "Cancelled caller must not release the cookie mutation lease")
                    browserStore.delayDelete = false
                    browserStore.holdDelete!!.invoke()
                    browserStore.holdDelete = null
                    withTimeout(2_000) { while (session.state.value.isSignedIn) yield() }
                    withTimeout(2_000) { request.awaitFinished() }
                    assertEquals(emptyList(), replies)
                } else {
                    assertTrue(request("session.signOut", "{\"confirmed\":true}").contains("\"ok\":true"))
                }
                if (browserCookies) {
                    assertFalse(browserStore.jar.any { it.name == authName && it.domain == ".$host" }, "Sign-out left browser auth available for the next seed/drain")
                    assertTrue(browserStore.jar.any { it.domain == "unrelated.example" }, "Unrelated site cookies must survive")
                    assertFalse(session.peek().isSignedIn)
                }
            } else {
                jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-b"
                assertTrue(request("session.sync").contains("\"ok\":true"))
            }
            // Keep the event's only producer alive until its bounded await completes.
            if (signOut) assertEquals(NotificationCounts(), withTimeout(2_000) { publishedCounts.await() }, "Signed-out publication must not carry old unread counts")
            // No refresh and no second native request is necessary to remove the old badge.
            assertEquals(NotificationCounts(), counts.counts.value)
        } finally {
            try {
                withTimeout(2_000) {
                    stateWatcher?.cancelAndJoin()
                    browserStore.delayDelete = false
                    browserStore.holdDelete?.invoke()
                    browserStore.holdDelete = null
                    requests.forEach { it.cancel() }
                    requests.forEach { it.awaitFinished() }
                }
            } finally {
                try {
                    withTimeout(2_000) { storeJob.cancelAndJoin() }
                } finally {
                    browserStore.jar.clear()
                    if (storeJob.isCompleted) file.delete()
                    Dispatchers.resetMain()
                }
            }
        }
    }

    /**
     * Legacy bypass reproduction ONLY: no boundary is passed into this raw composer.
     * Its obsolete automatic-deletion assertion deliberately stays RED under preserve/deny.
     * Production graph behavior lives in NativePrivateGraphIntegrationTest instead.
     */
    fun accountSwitchMustClearGlobalDraftRegression() = runBlocking {
        Dispatchers.setMain(Dispatchers.Unconfined)
        val job = SupervisorJob()
        val file = java.io.File(System.getProperty("java.io.tmpdir"), "draft-boundary-${java.util.UUID.randomUUID()}.preferences_pb")
        try {
            val store = PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { file.path.toPath() })
            val drafts = io.github.nodyssey.data.composer.DefaultPostComposerRepository(
                store, fixture<HttpTransport> { error("No live HTTP allowed") },
                io.github.plaza.core.AppDispatchers(), AppClock.System,
            )
            val jar = Jar().apply { header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-a" }
            val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
            NodysseyApp.fixture = IosAppContainer(mapOf("sessionRepository" to session, "postRepository" to postRepository(), "notificationRepository" to notifications(), "postComposerRepository" to drafts))
            suspend fun request(op: String) {
                val result = CompletableDeferred<String>()
                val request = NativeBridge.request(op, "{}") { result.complete(it) }
                assertTrue(withTimeout(2_000) { result.await() }.contains("\"ok\":true"))
                request.awaitFinished()
            }
            request("session.snapshot")
            drafts.saveDraft(io.github.nodyssey.data.composer.PostDraft(title = "account-a-private-fixture", body = "unsent"))
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=account-b"
            request("session.sync")
            assertNull(drafts.draft.first(), "Account B inherited account A's persistent draft")
        } finally {
            try {
                withTimeout(2_000) { job.cancelAndJoin() }
            } finally {
                if (job.isCompleted) file.delete()
                Dispatchers.resetMain()
            }
        }
    }

    @Test
    fun delayedSignInAfterCancelCompletesInsteadOfHanging() = authenticationCase("session.cancelSignIn")

    @Test
    fun delayedSignInAfterSyncCompletesInsteadOfHanging() = authenticationCase("session.sync")

    @Test
    fun cancelDuringSessionSettleCannotPublishStaleSuccess() = authenticationCase("session.cancelSignIn", settling = true)

    @Test
    fun trueCallerCancellationDoesNotDeliverAnError() = authenticationCase("session.cancelSignIn", callerCancelled = true)

    @Test
    fun cancelledCallerWithAlreadyInstalledCookiesStillReconcilesSession() = authenticationCase("session.cancelSignIn", callerCancelled = true, responseAfterCancellation = true)

    @Test
    fun ordinaryAuthErrorAfterCookieAndSupersessionSynchronizesSession() = authenticationCase("session.cancelSignIn", ordinaryError = true)

    @Test
    fun ordinaryAuthErrorAfterCookieSynchronizesSessionWithoutReportingSigned() = authenticationCase(ordinaryError = true)

    @Test
    fun ordinaryAuthErrorWithoutCookieRemainsSignedOut() = authenticationCase(ordinaryError = true, installCookie = false)

    @Test
    fun ordinaryAuthErrorAfterCallerCancellationSynchronizesWithoutCallback() = authenticationCase(ordinaryError = true, callerCancelled = true, responseAfterCancellation = true)

    @Test
    fun parserErrorAfterCookieKeepsSanitizedErrorAndSynchronizesSession() = authenticationCase(ordinaryError = true, parserError = true)

    @Test
    fun normalSignInPublishesSignedSessionExactlyOnce() = authenticationCase()

    private fun authenticationCase(operation: String? = null, settling: Boolean = false, callerCancelled: Boolean = false, responseAfterCancellation: Boolean = false, ordinaryError: Boolean = false, installCookie: Boolean = true, parserError: Boolean = false) = runBlocking {
        Dispatchers.setMain(Dispatchers.Unconfined)
        val release = CompletableDeferred<Unit>()
        val requests = mutableListOf<NativeRequest>()
        try {
            val jar = Jar()
            val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, jar), deferPublication = true)
            val entered = CompletableDeferred<Unit>()

            val signIn = object : SignInRepository {
                override suspend fun signIn(credentials: SignInCredentials): SignInOutcome {
                    entered.complete(Unit)
                    if (responseAfterCancellation) withContext(NonCancellable) { withTimeout(2_000) { release.await() } } else withTimeout(2_000) { release.await() }
                    if (!settling && installCookie) jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=delayed-fixture"
                    if (parserError) throw SiteException(SiteError.Unparsable)
                    if (ordinaryError) throw IllegalStateException("fixture failure after cookie installation")
                    return SignInOutcome.Signed
                }
                override suspend fun verifyTwoFactor(challenge: TwoFactorChallenge, code: String): SignInOutcome = error("unused")
            }
            val counts = notifications()
            NodysseyApp.fixture = IosAppContainer(mapOf(
                "sessionRepository" to session,
                "signInRepository" to signIn,
                "postRepository" to postRepository(),
                "notificationRepository" to counts,
                "clock" to AppClock.System,
            ))
            val replies = mutableListOf<String>()
            val completed = CompletableDeferred<Unit>()
            val request = NativeBridge.request("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""") {
                replies += it
                completed.complete(Unit)
            }
            requests += request
            withTimeout(2_000) { entered.await() }
            counts.refreshCounts()
            if (settling) release.complete(Unit)
            if (callerCancelled) request.cancel()
            if (operation != null) {
                val control = CompletableDeferred<String>()
                val controlRequest = NativeBridge.request(operation, "{}") { control.complete(it) }
                requests += controlRequest
                assertTrue(withTimeout(2_000) { control.await() }.contains("\"ok\":true"))
                controlRequest.awaitFinished()
            }
            if (settling) jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=settled-fixture"
            release.complete(Unit)
            withTimeout(2_000) { request.awaitFinished() }
            if (session.peek().isSignedIn) assertEquals(NotificationCounts(), counts.counts.value, "Failure and cancellation must reconcile unread counts too")
            if (callerCancelled) {
                assertEquals(emptyList(), replies)
                assertEquals(session.peek(), session.state.value, "Caller cancellation must reconcile cookies already installed by the transport")
                return@runBlocking
            }
            withTimeout(2_000) { completed.await() }
            assertEquals(1, replies.size, "Authentication must complete the live Swift continuation exactly once")
            val failed = ordinaryError || operation != null
            val expected = when {
                parserError -> "UNPARSABLE"
                ordinaryError -> "INTERNAL"
                operation != null -> "SIGN_IN_SUPERSEDED"
                else -> "SIGNED"
            }
            assertTrue(replies.single().contains(expected), replies.single())
            assertTrue(replies.single().contains("\"ok\":${!failed}"), replies.single())
            if (failed) assertFalse(replies.single().contains("SIGNED"), "Failed authentication must not report SIGNED")
            assertFalse(replies.single().contains("fixture"), "Repository exception and credentials must be sanitized")
            assertEquals(installCookie, session.peek().isSignedIn)
            assertEquals(session.peek(), session.state.value, "A response that installed cookies must not leave the published state stale")
        } finally {
            try {
                release.complete(Unit)
                requests.forEach { it.cancel() }
                withTimeout(2_000) { requests.forEach { it.awaitFinished() } }
            } finally {
                Dispatchers.resetMain()
            }
        }
    }
}

/** Separate release gate: production publishes session before suspending count reconciliation. */
class NativeSessionPublicationOpenTest {
    @Test
    fun signedOutPublicationMustHaveZeroCountsWhileReconciliationSuspends() = NativeSessionSecurityJvmTest().signedOutPublicationWhileReconciliationSuspendsRegression()
}
