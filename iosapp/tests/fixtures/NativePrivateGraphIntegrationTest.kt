package io.github.nodyssey.ios.native

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.room.Room
import androidx.room.useReaderConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.net.JsonApi
import io.github.nodyssey.core.net.NodeSeekJsonClient
import io.github.nodyssey.data.*
import io.github.nodyssey.data.composer.*
import io.github.nodyssey.data.local.*
import io.github.nodyssey.data.offline.*
import io.github.nodyssey.data.session.*
import io.github.nodyssey.data.settings.*
import io.github.nodyssey.ios.*
import io.github.nodyssey.model.*
import io.github.plaza.core.*
import io.github.plaza.core.net.*
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import okio.Path.Companion.toPath
import org.junit.Test
import kotlin.test.*

/** Exact production inventory/wrappers + NativeBridge + draft/offline cases, JVM graph fixture. */
@OptIn(ExperimentalCoroutinesApi::class)
class NativePrivateGraphIntegrationTest {
    private class Jar : SessionCookieStore {
        var header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-a"
        override fun cookieHeader(url: String) = header
        override fun setCookie(url: String, cookie: String) { error("No network") }
        override suspend fun removeAll() { header = "" }
        override fun flush() = Unit
    }
    private inline fun <reified T> unused(): T = Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, method, _ -> error("Unexpected I/O: ${method.name}") } as T

    private class Disk(val root: File, val jar: Jar) {
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.Default)
        fun store(name: String) = PreferenceDataStoreFactory.createWithPath(scope = scope, produceFile = { File(root, "$name.preferences_pb").path.toPath() })
        val post = store("post-composer")
        val comment = store("comment-composer")
        val settingsStore = store("settings")
        val settings = SettingsRepository(settingsStore)
        val journal = store("private-store-provenance")
        val db = Room.databaseBuilder<NodeSeekDatabase>(File(root, "real.db").path).setDriver(BundledSQLiteDriver()).build()
        val files = GraphFiles(File(root, "offline-files"))
        val cookies = SessionCookies(NodeSeekSite.CONFIG, jar)
        val session = SessionRepository(cookies, deferPublication = true)
        val clock = AppClock.System
        val dispatchers = AppDispatchers()
        val transport = Proxy.newProxyInstance(HttpTransport::class.java.classLoader, arrayOf(HttpTransport::class.java)) { _, _, _ -> error("No live transport permitted") } as HttpTransport
        val rawPostDraft = DefaultPostComposerRepository(post, transport, dispatchers, clock)
        val rawCommentDraft = DefaultCommentComposerRepository(comment, transport, dispatchers, clock)
        var authCalls = 0
        var authResponse = """{"success":true}"""
        val authTransport = object : HttpTransport {
            override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse {
                check(request.method == "POST" && request.url.endsWith(NodeSeekJsonClient.PATH_ACCOUNT_SIGN_IN))
                authCalls++
                jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=new-authenticated-owner"
                return HttpResponse(200, request.url, emptyMap(), authResponse)
            }
        }
        var loadDetail: suspend (Long, Int) -> PostDetail = { _, _ -> error("No live download") }
        val remote = object : PostRemoteDataSource {
            override suspend fun loadList(categorySlug: String?, page: Int, sort: FeedSort): PostListPage = error("No live list")
            override suspend fun loadSearch(query: String, page: Int, categorySlug: String?, sort: FeedSort): PostListPage = error("No live search")
            override suspend fun loadDetail(postId: Long, page: Int): PostDetail = loadDetail.invoke(postId, page)
        }
        val rawPosts = OfflineFirstPostRepository(db, remote, clock)
        val rawOffline = RoomOfflineLibrary(db.offlineDao(), remote, files,
            object : OfflineImageSource { override suspend fun fetch(url: String, maxBytes: Long): ByteArray? = error("No live image") },
            OfflineSettingsStore(store("offline")), RoomCollectedPostMetaStore(db.collectedPostMetaDao(), clock),
            object : OfflineWorkScheduler {
                override fun startDrain(wifiOnly: Boolean, restart: Boolean) = Unit
                override fun ensureMaintenance() = Unit
            }, clock, dispatchers)
        val graph: IosAppContainer
        init {
            val notifications = NotificationRepository(Proxy.newProxyInstance(JsonApi::class.java.classLoader, arrayOf(JsonApi::class.java)) { _, _, _ -> error("No HTTP") } as JsonApi)
            // Cleanup uses the real DAO. All unrelated profile operations fail rather than fake success.
            val unusedProfile = Proxy.newProxyInstance(ProfileRepository::class.java.classLoader, arrayOf(ProfileRepository::class.java)) { _, _, _ -> error("unused profile") } as ProfileRepository
            val profile = object : ProfileRepository by unusedProfile {
                override suspend fun clearCachedProfile() = db.profileDao().deleteAll()
            }
            val values = mutableMapOf<String, Any>(
                "postDraftStore" to post, "commentDraftStore" to comment,
                "settingsDataStore" to settingsStore, "private-store-provenance" to journal,
                "settingsRepository" to settings, "reportCompareStore" to settings.reportCompare,
                "database" to db, "sessionCookies" to cookies, "sessionRepository" to session,
                "notificationRepository" to notifications, "rawPostRepository" to rawPosts,
                "rawOfflineLibrary" to rawOffline, "offlineFiles" to files,
                "transport" to transport, "dispatchers" to dispatchers, "clock" to clock,
                "userAgent" to UserAgent("fixture", true),
                "signInRepository" to NodeSeekSignInRepository(NodeSeekJsonClient(authTransport, dispatchers)),
                "profileRepository" to profile, "userNoteStore" to UserNoteStore(db.userNoteDao(), clock),
                "trackedThreadStore" to TrackedThreadStore(db.trackedThreadDao(), clock),
            )
            graph = IosAppContainer(values)
            values["postRepository"] = PrivatePostRepository(rawPosts, graph.privateBoundary)
            values["accountSignOut"] = AccountSignOut { session.signOut() }
            NodysseyApp.fixture = graph
        }
        suspend fun close() { job.cancelAndJoin(); db.close() }
        suspend fun seedRaw() {
            rawPostDraft.saveDraft(PostDraft(title = "owner-a-title", body = "owner-a-unsent"))
            rawCommentDraft.saveDraft(42, CommentDraft(body = "owner-a-comment"))
            rawOffline.download(listOf(42))
            seedDownloadedPage()
        }
        suspend fun seedDownloadedPage() {
            val floor = PostContent(7, "#0", "owner-a-author", 1, null, false, emptyList(), null, null, null, emptyList())
            val dao = db.offlineDao()
            val queued = requireNotNull(dao.find(42))
            dao.upsert(queued.copy(title = "owner-a-offline", body = floor, status = OfflineStatus.DOWNLOADED, downloadedAtMillis = 10L))
            dao.upsertComments(listOf(OfflineCommentEntity(42, 1, 0, floor.copy(commentId = 8, floor = "#1"))))
            val url = "https://fixture.invalid/private"
            val name = files.nameOf(url)
            files.write(name, byteArrayOf(1, 2, 3))
            dao.upsertImages(listOf(OfflineImageEntity(42, url, name, 3)))
        }
        suspend fun assertRawPresent() {
            assertEquals("owner-a-title", rawPostDraft.draft.first()?.title)
            assertEquals("owner-a-comment", rawCommentDraft.draft(42).first()?.body)
            assertEquals("owner-a-offline", rawOffline.storedPage(42, 1)?.detail?.title)
            assertEquals(1, db.offlineDao().comments(42, 1).size)
            assertEquals(1, db.offlineDao().images(42).size)
            assertFalse(files.isEmpty())
        }
    }
    private suspend fun request(op: String, args: String = "{}"): JsonObject {
        val reply = CompletableDeferred<String>()
        val handle = NativeBridge.request(op, args) { reply.complete(it) }
        val completed = CompletableDeferred<Unit>()
        handle.invokeOnCompletion { completed.complete(Unit) }
        try {
            val value = withTimeout(5_000) { reply.await() }
            withTimeout(5_000) { completed.await() }
            return Json.parseToJsonElement(value).jsonObject
        } finally { handle.cancel(); withTimeout(5_000) { completed.await() } }
    }
    private suspend fun success(op: String, args: String = "{}"): JsonElement {
        val reply = request(op, args)
        assertEquals(JsonPrimitive(true), reply["ok"], reply.toString())
        return reply.getValue("data")
    }
    private suspend fun denied(op: String, args: String = "{}") {
        val reply = request(op, args)
        assertEquals(JsonPrimitive(false), reply["ok"], reply.toString())
        assertTrue(reply.toString().contains("PRIVATE_STORE_RECOVERY_REQUIRED"), reply.toString())
        assertFalse(reply.toString().contains("owner-a-"))
    }
    private suspend fun assertNativeDenied(d: Disk) {
        denied("draft.post.get")
        denied("draft.comment.get", """{"postId":42}""")
        denied("offline.get")
        denied("draft.post.save", """{"title":"wrong-owner","body":"bad","permission":0}""")
        denied("draft.comment.save", """{"postId":42,"body":"wrong-owner"}""")
        denied("offline.download", """{"postIds":[99]}""")
        assertNull(d.db.offlineDao().find(99))
        assertFailsWith<PrivateStoreAccessDenied> { d.graph.postComposerRepository.draft.first() }
        assertFailsWith<PrivateStoreAccessDenied> { d.graph.commentComposerRepository.draft(42).first() }
        assertFailsWith<PrivateStoreAccessDenied> { d.graph.offlineLibrary.states.first() }
        assertFailsWith<PrivateStoreAccessDenied> { (d.graph.offlineLibrary as OfflineThreadReader).storedPage(42, 1) }
        assertFailsWith<PrivateStoreAccessDenied> { (d.graph.offlineLibrary as OfflineDownloads).drainQueue() }
    }
    private fun scenario(block: suspend (File, Jar) -> Unit) = runBlocking {
        Dispatchers.setMain(Dispatchers.Unconfined)
        val root = File(System.getProperty("java.io.tmpdir"), "graph-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        try { withTimeout(20_000) { block(root, Jar()) } }
        finally {
            coil3.SingletonImageLoader.loader.memoryCache!!.clear()
            coil3.SingletonImageLoader.loader.diskCache!!.clear()
            Dispatchers.resetMain()
            root.deleteRecursively()
        }
    }

    private suspend fun displayedEpoch(): String = success("session.privateBoundary").jsonObject.getValue("identityEpoch").jsonPrimitive.content
    private suspend fun reset(): JsonElement {
        val epoch = displayedEpoch()
        return success("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$epoch"}""")
    }

    private suspend fun firstObservation(operation: String): JsonObject {
        val reply = CompletableDeferred<String>()
        val handle = NativeBridge.observe(operation, "{}") { reply.complete(it) }
        val finished = CompletableDeferred<Unit>()
        handle.invokeOnCompletion { finished.complete(Unit) }
        try {
            val envelope = Json.parseToJsonElement(withTimeout(5_000) { reply.await() }).jsonObject
            assertEquals(JsonPrimitive(true), envelope["ok"], envelope.toString())
            return envelope.getValue("data").jsonObject
        } finally {
            handle.cancel()
            withTimeout(5_000) { finished.await() }
        }
    }

    /** Replays NativeAppModel.runStart's public bootstrap against the production bridge, not a transport double. */
    private suspend fun assertRecoveryStartup(d: Disk, phase: PrivateStorePhase) {
        val preferences = platform.Foundation.NSUserDefaults.standardUserDefaults
        val current = io.github.nodyssey.core.ActiveSite.current
        val selected = io.github.nodyssey.core.Site.entries.first { it != current }
        preferences.values["active_site"] = selected.storedValue
        val beforeJournal = d.journal.data.first()
        val beforePost = d.post.data.first()
        val beforeComment = d.comment.data.first()
        val beforeSettings = d.settingsStore.data.first()
        preferences.writes = 0
        NodysseyApp.graphRequests = 0

        // Must succeed BEFORE the three observers exist, with the real active site,
        // even when the next-launch selection differs. Must not open the private graph.
        val site = success("site.get").jsonObject
        assertEquals(0, NodysseyApp.graphRequests, "Public metadata must not construct/read/reconcile private stores")
        assertEquals(setOf("current", "selected", "requiresRestart", "sites"), site.keys)
        assertEquals(JsonPrimitive(current.name), site["current"])
        assertEquals(JsonPrimitive(selected.name), site["selected"])
        assertEquals(JsonPrimitive(true), site["requiresRestart"])
        val active = site.getValue("sites").jsonArray.single { it.jsonObject["id"] == JsonPrimitive(current.name) }.jsonObject
        assertEquals(JsonPrimitive(current.origin), active["origin"])
        assertEquals(JsonPrimitive(current.displayName), active["displayName"])
        assertEquals(setOf("id", "displayName", "origin", "hosts", "oneTapSignInPath", "oneTapProviderName"), active.keys)
        assertEquals(beforeJournal, d.journal.data.first(), "No bootstrap provenance adoption")
        assertEquals(beforeSettings, d.settingsStore.data.first(), "Metadata must not touch mixed settings")
        assertEquals(0, preferences.writes, "Reading metadata must not change next-launch selection")

        val session = firstObservation("session.state")
        val settings = firstObservation("settings.observe")
        val boundary = firstObservation("session.privateBoundary")
        assertEquals(JsonPrimitive(phase.name), boundary["phase"])
        assertEquals(JsonPrimitive(true), boundary["requiresConfirmation"])
        assertEquals(session["identityEpoch"], boundary["identityEpoch"])
        assertTrue(boundary.getValue("identityEpoch").jsonPrimitive.content.isNotEmpty())
        assertNotNull(session["generation"])
        assertNotNull(session["isSignedIn"])
        assertFalse(settings.containsKey("searchHistory"))
        assertFalse(settings.containsKey("recentBoards"))
        assertFalse((site.toString() + session + settings + boundary).contains("owner-a-"))
        assertEquals(beforePost, d.post.data.first())
        assertEquals(beforeComment, d.comment.data.first())
        // Recovery observation intentionally initializes cleared notification counters;
        // every pre-existing preference/private mixed-store value must still be preserved.
        val afterSettings = d.settingsStore.data.first().asMap()
        for ((key, value) in beforeSettings.asMap()) assertEquals(value, afterSettings[key])
        d.assertRawPresent()

        // No site.* or supplement-wide admission exemption: private reads/writes,
        // next-launch mutation, secrets and future operations still fail closed.
        for (op in listOf("site.select", "site.future", "search.history.get", "search.history.clear",
            "boards.recent.get", "boards.recent.record", "reports.parse", "imageHost.get", "proxy.get")) {
            denied(op)
        }
        assertEquals(0, preferences.writes)
        assertNativeDenied(d)
        d.assertRawPresent()
    }

    @Test
    fun successfulPasswordLoginAfterPublicStartupAdmitsEmptyStores() = scenario { root, jar ->
        jar.header = ""
        var d = Disk(root, jar)
        try {
            success("site.get")
            firstObservation("session.state")
            firstObservation("settings.observe")
            firstObservation("session.privateBoundary")
            val guestEpoch = displayedEpoch()
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase)
            val signed = success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""").jsonObject
            assertEquals(JsonPrimitive("SIGNED"), signed["status"])
            assertEquals(1, d.authCalls, "Execute actual sign-in parser and JSON client via native dispatch")
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase,
                "Successful clean login must not strand My behind private-data recovery")
            assertNotEquals(guestEpoch, displayedEpoch(), "New auth identity must revoke guest epoch")
            assertEquals(JsonNull, success("draft.post.get"))
            d.close()
            d = Disk(root, jar)
            assertEquals(JsonNull, success("draft.post.get"), "Rebound provenance survives real DataStore reopen")
        } finally { d.close() }
    }

    @Test
    fun successfulLoginWithGuestBrowsingDataPreservesItAndReportsPrivacyGate() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        try {
            firstObservation("session.state")
            firstObservation("settings.observe")
            firstObservation("session.privateBoundary")
            // Public board browsing writes private history through the production supplement dispatcher.
            success("boards.recent.record", """{"categorySlug":"trade"}""")
            assertEquals(listOf("trade"), d.settings.settings.first().recentBoards)
            val signed = success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""").jsonObject
            assertEquals(JsonPrimitive("SIGNED"), signed["status"])
            assertTrue(d.session.state.value.isSignedIn)
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            assertEquals(listOf("trade"), d.settings.settings.first().recentBoards, "Guest bytes are not B's data")
            denied("boards.recent.get")
            assertEquals(JsonPrimitive("CONFIRMATION_REQUIRED"), signed["privateDataStatus"],
                "Successful authentication must explicitly distinguish locked private data from login failure")
            assertEquals(d.graph.privateBoundary.state.value.nativeBoundaryDto(), signed["privateBoundary"])
        } finally { d.close() }
    }

    @Test
    fun successfulLoginWithRoomGuestThreadDoesNotAdoptCachedContent() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        try {
            firstObservation("session.state")
            val body = PostContent(7, "#0", "public-author", 1, null, false, emptyList(), null, null, null, emptyList())
            d.loadDetail = { id, page -> PostDetail(postId = id, title = "public-thread", body = body, comments = emptyList(), page = page, totalPages = 1, hasNextPage = false) }
            d.graph.postRepository.refreshThread(42, 1)
            assertNotNull(d.rawPosts.thread(42).first())
            success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""")
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            assertNotNull(d.rawPosts.thread(42).first(), "Preserve guest Room bytes, never reassign them to a new auth owner")
            assertFailsWith<PrivateStoreAccessDenied> { d.graph.postRepository.thread(42).first() }
        } finally { d.close() }
    }

    @Test
    fun malformedSignInResponseAfterCookieNeverUsesEmptyRebind() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        try {
            firstObservation("session.state")
            d.authResponse = "not-json"
            val failed = request("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""")
            assertEquals(JsonPrimitive(false), failed["ok"])
            assertTrue(d.session.state.value.isSignedIn, "Cookie-side effects are reconciled even on parse error")
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            denied("draft.post.get")
        } finally { d.close() }
    }

    @Test
    fun newBytesDuringEmptyLoginPreventRebind() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        try {
            firstObservation("session.state")
            d.graph.privateBoundary.sessionMutation(allowEmptyRebind = { _: Unit -> true }) {
                jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-b"
                d.rawPostDraft.saveDraft(PostDraft(title = "unattributed-late-bytes"))
            }
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            assertEquals("unattributed-late-bytes", d.rawPostDraft.draft.first()?.title)
            denied("draft.post.get")
        } finally { d.close() }
    }

    @Test
    fun interruptedEmptyJournalCannotGainTrustThroughSuccessfulLogin() = scenario { root, jar ->
        jar.header = ""
        var d = Disk(root, jar)
        try {
            firstObservation("session.state")
            d.graph.privateBoundary.beginExternalMutation()
            d.close()
            d = Disk(root, jar)
            val signed = success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""").jsonObject
            assertEquals(JsonPrimitive("SIGNED"), signed["status"])
            assertEquals(JsonPrimitive("CONFIRMATION_REQUIRED"), signed["privateDataStatus"])
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            denied("draft.post.get")
        } finally { d.close() }
    }

    @Test
    fun emptyLoginInventoryWaitsForNonCancellableGuestWriter() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        val entered = CompletableDeferred<Unit>()
        val draining = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var writer: Job? = null
        var login: Deferred<JsonElement>? = null
        try {
            firstObservation("session.state")
            writer = d.scope.launch {
                d.graph.privateBoundary.protect {
                    entered.complete(Unit)
                    try { awaitCancellation() } finally {
                        withContext(NonCancellable) {
                            draining.complete(Unit)
                            release.await()
                            d.rawPostDraft.saveDraft(PostDraft(title = "guest-finally-write"))
                        }
                    }
                }
            }
            withTimeout(5_000) { entered.await() }
            login = d.scope.async { success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""") }
            withTimeout(5_000) { draining.await() }
            assertEquals(0, d.authCalls, "Auth may not run before the old writer terminates")
            assertFalse(login.isCompleted)
            release.complete(Unit)
            val signed = withTimeout(5_000) { login.await() }.jsonObject
            writer.join()
            assertEquals(JsonPrimitive("SIGNED"), signed["status"])
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            assertEquals("guest-finally-write", d.rawPostDraft.draft.first()?.title)
            denied("draft.post.get")
        } finally {
            release.complete(Unit)
            login?.cancelAndJoin()
            writer?.cancelAndJoin()
            d.close()
        }
    }

    @Test
    fun successfulLoginNeverAdoptsUntrustedLegacyData() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        try {
            d.seedRaw()
            firstObservation("session.state")
            val signed = success("session.signIn", """{"account":"fixture","password":"fixture","verificationToken":"fixture"}""").jsonObject
            assertEquals(JsonPrimitive("SIGNED"), signed["status"])
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase)
            assertNativeDenied(d)
            d.assertRawPresent()
        } finally { d.close() }
    }

    @Test
    fun successfulBrowserLoginAfterPublicStartupAdmitsEmptyStoresOnlyAfterClose() = scenario { root, jar ->
        jar.header = ""
        val d = Disk(root, jar)
        val storage = platform.Foundation.NSHTTPCookieStorage.sharedHTTPCookieStorage
        val web = platform.WebKit.WKHTTPCookieStore()
        storage.cookies.forEach(storage::deleteCookie)
        val browser = NativeBrowserSession(web, "login")
        try {
            firstObservation("session.state")
            firstObservation("settings.observe")
            firstObservation("session.privateBoundary")
            val before = displayedEpoch()
            val started = CompletableDeferred<String?>()
            browser.start { _, error -> started.complete(error) }
            assertNull(withTimeout(5_000) { started.await() })
            assertEquals(PrivateStorePhase.TRANSITIONING, d.graph.privateBoundary.state.value.phase)
            // Fixture adapter mirrors Foundation's real bridge output into the graph's cookie authority.
            val name = NodeSeekSite.CONFIG.sessionCookieNames.first()
            val host = requireNotNull(WebUrl.parse(NodeSeekSite.BASE_URL)?.host)
            web.setCookie(platform.Foundation.NSHTTPCookie(name, "browser-owner", host)) {}
            jar.header = storage.cookies.joinToString("; ") { "${it.name}=${it.value}" }
            assertTrue(browser.goalReached())
            denied("draft.post.get")
            val closed = CompletableDeferred<String?>()
            browser.close { closed.complete(it) }
            assertNull(withTimeout(5_000) { closed.await() })
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase)
            assertNotEquals(before, displayedEpoch())
            assertEquals(JsonNull, success("draft.post.get"))
        } finally {
            val closed = CompletableDeferred<String?>()
            browser.close { closed.complete(it) }
            withTimeout(5_000) { closed.await() }
            storage.cookies.forEach(storage::deleteCookie)
            d.close()
        }
    }

    @Test
    fun unknownColdStartupLoadsPublicSiteBeforeRecoveryObserversWithoutPrivateAccess() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            d.seedRaw()
            d.settings.recordRecentBoard("trade")
            assertRecoveryStartup(d, PrivateStorePhase.UNKNOWN)
        } finally { d.close() }
    }

    @Test
    fun interruptedColdStartupLoadsPublicSiteBeforeRecoveryObserversWithoutPrivateAccess() = scenario { root, jar ->
        var d = Disk(root, jar)
        try {
            d.seedRaw()
            success("session.privateBoundary")
            // Persist an interrupted manifest with the exact inventory; reopening must
            // preserve TRANSITIONING, not treat this as a fresh/empty install.
            val key = stringPreferencesKey("private-store-manifest-v1")
            d.journal.edit { prefs ->
                val manifest = Json.parseToJsonElement(requireNotNull(prefs[key])).jsonObject
                prefs[key] = JsonObject(manifest + ("phase" to JsonPrimitive("TRANSITIONING"))).toString()
            }
            d.close()
            d = Disk(root, jar)
            assertRecoveryStartup(d, PrivateStorePhase.TRANSITIONING)
        } finally { d.close() }
    }

    @Test
    fun unknownPreservesBothDraftsOfflineAndFilesButDeniesReadsAndWrites() = scenario { root, jar ->
        var d = Disk(root, jar)
        try {
            d.seedRaw()
            success("session.privateBoundary")
            assertNativeDenied(d)
            d.assertRawPresent()
            d.close()
            d = Disk(root, jar)
            success("session.privateBoundary")
            assertNativeDenied(d)
            d.assertRawPresent()
        } finally { d.close() }
    }

    @Test
    fun sameOwnerRelaunchKeepsBothDraftsAndOfflineReadableThenSwitchDeniesWithoutDeletion() = scenario { root, jar ->
        var d = Disk(root, jar)
        try {
            success("session.privateBoundary")
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase)
            success("draft.post.save", """{"title":"owner-a-title","body":"owner-a-unsent","permission":0}""")
            success("draft.comment.save", """{"postId":42,"body":"owner-a-comment"}""")
            success("offline.download", """{"postIds":[42]}""")
            d.seedDownloadedPage()
            d.close()
            d = Disk(root, jar)
            assertTrue(success("draft.post.get").toString().contains("owner-a-title"))
            assertTrue(success("draft.comment.get", """{"postId":42}""").toString().contains("owner-a-comment"))
            assertTrue(success("offline.get").toString().contains("42"))
            d.assertRawPresent()
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-b"
            success("session.sync")
            assertNativeDenied(d)
            d.assertRawPresent()
        } finally { d.close() }
    }

    @Test
    fun onlyDisplayedConfirmedResetClearsPrivateDataAndPreservesGlobalPreferences() = scenario { root, jar ->
        var d = Disk(root, jar)
        try {
            d.seedRaw()
            coil3.SingletonImageLoader.loader.memoryCache!!.keys += "owner-a-image-memory"
            coil3.SingletonImageLoader.loader.diskCache!!.keys += "owner-a-image-disk"
            d.settings.setReadHistoryLimit(100)
            d.settingsStore.edit {
                it[stringPreferencesKey("recent_searches")] = "legacy-query"
                it[stringPreferencesKey("search_history_v3")] = "[]"
                it[stringPreferencesKey("unrelated-global-fixture")] = "preserve-me"
            }
            d.settings.recordRecentBoard("trade")
            val shown = displayedEpoch()
            denied("session.resetPrivateStores", """{"confirmed":false,"identityEpoch":"$shown"}""")
            denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"not-the-displayed-epoch"}""")
            d.assertRawPresent()
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-b"
            success("session.sync")
            denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$shown"}""")
            d.assertRawPresent()
            assertTrue(coil3.SingletonImageLoader.loader.memoryCache!!.keys.contains("owner-a-image-memory"))
            assertTrue(coil3.SingletonImageLoader.loader.diskCache!!.keys.contains("owner-a-image-disk"))
            reset()
            assertTrue(coil3.SingletonImageLoader.loader.memoryCache!!.keys.isEmpty())
            assertTrue(coil3.SingletonImageLoader.loader.diskCache!!.keys.isEmpty())
            assertEquals(JsonNull, success("draft.post.get"))
            assertEquals(JsonNull, success("draft.comment.get", """{"postId":42}"""))
            assertNull(d.db.offlineDao().find(42))
            assertEquals(0, d.db.offlineDao().comments(42, 1).size)
            assertEquals(0, d.db.offlineDao().images(42).size)
            assertTrue(d.files.isEmpty())
            assertTrue(d.settings.settings.first().recentBoards.isEmpty())
            assertTrue(d.settings.settings.first().searchHistory.isEmpty())
            assertEquals("preserve-me", d.settingsStore.data.first()[stringPreferencesKey("unrelated-global-fixture")])
            assertEquals(100, d.settings.settings.first().readHistoryLimit)
            for (key in listOf("recent_searches", "search_history_v3", "recent_boards")) {
                assertNull(d.settingsStore.data.first()[stringPreferencesKey(key)])
            }
            d.close()
            d = Disk(root, jar)
            assertEquals(JsonNull, success("draft.post.get"))
            assertEquals(JsonNull, success("draft.comment.get", """{"postId":42}"""))
            assertTrue(d.graph.offlineLibrary.states.first().isEmpty())
            assertEquals(100, d.settings.settings.first().readHistoryLimit)
        } finally { d.close() }
    }

    @Test
    fun cancelledTransitionsExposeRecoveryOnlyAfterWriterDrain() = scenario { root, jar ->
        for (kind in listOf("session", "external", "reset")) {
            val d = Disk(File(root, kind).apply { mkdirs() }, jar)
            val release = CompletableDeferred<Unit>()
            var writer: Job? = null
            var transition: Job? = null
            try {
                val before = displayedEpoch()
                d.seedRaw()
                val entered = CompletableDeferred<Unit>()
                val draining = CompletableDeferred<Unit>()
                writer = d.scope.launch {
                    d.graph.privateBoundary.protect {
                        entered.complete(Unit)
                        try { awaitCancellation() }
                        finally {
                            withContext(NonCancellable) {
                                draining.complete(Unit)
                                release.await()
                            }
                        }
                    }
                }
                entered.await()
                transition = d.scope.launch {
                    when (kind) {
                        "session" -> d.graph.privateBoundary.sessionMutation { error("Cancelled before mutation") }
                        "external" -> d.graph.privateBoundary.beginExternalMutation()
                        else -> d.graph.privateBoundary.reset(true, before)
                    }
                }
                draining.await()
                transition.cancel()
                val active = success("session.privateBoundary").jsonObject
                assertEquals(JsonPrimitive("TRANSITIONING"), active["phase"])
                assertEquals(JsonPrimitive(false), active["recoveryEligible"])
                assertFalse(transition.isCompleted)
                val activeEpoch = active.getValue("identityEpoch").jsonPrimitive.content
                // Must reject now, not queue a destructive request until the cancelled writer drains.
                withTimeout(1000) {
                    denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$activeEpoch"}""")
                }
                d.assertRawPresent()
                release.complete(Unit)
                transition.join()
                writer.join()
                val drained = d.graph.privateBoundary.state.value.nativeBoundaryDto()
                assertEquals(JsonPrimitive("TRANSITIONING"), drained["phase"])
                assertEquals(JsonPrimitive(true), drained["recoveryEligible"])
                assertFailsWith<PrivateStoreAccessDenied> { d.graph.privateBoundary.protect { error("Private admission") } }
                d.assertRawPresent()
                denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$before"}""")
                val shown = success("session.privateBoundary").jsonObject
                assertEquals(JsonPrimitive(true), shown["recoveryEligible"])
                val epoch = shown.getValue("identityEpoch").jsonPrimitive.content
                denied("session.resetPrivateStores", """{"confirmed":false,"identityEpoch":"$epoch"}""")
                d.assertRawPresent()
                val ready = success("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$epoch"}""").jsonObject
                assertEquals(JsonPrimitive("READY"), ready["phase"])
                assertEquals(JsonPrimitive(false), ready["recoveryEligible"])
                assertTrue(d.files.isEmpty())
            } finally {
                release.complete(Unit)
                transition?.cancelAndJoin()
                writer?.cancelAndJoin()
                d.close()
            }
        }
    }

    @Test
    fun externalWriterRetainsRecoveryClosureUntilExplicitFinish() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            d.seedRaw()
            val before = displayedEpoch()
            d.graph.privateBoundary.beginExternalMutation()
            val active = success("session.privateBoundary").jsonObject
            assertEquals(JsonPrimitive(false), active["recoveryEligible"])
            val epoch = active.getValue("identityEpoch").jsonPrimitive.content
            denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$epoch"}""")
            d.assertRawPresent()
            d.graph.privateBoundary.finishExternalMutation()
            val drained = success("session.privateBoundary").jsonObject
            assertEquals(JsonPrimitive(true), drained["recoveryEligible"])
            assertNotEquals(before, drained.getValue("identityEpoch").jsonPrimitive.content)
            denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$before"}""")
            d.assertRawPresent()
            reset()
            assertTrue(d.files.isEmpty())
        } finally { d.close() }
    }

    @Test
    fun interruptedConfirmedResetReopensFailClosedUntilNewDisplayedConfirmation() = scenario { root, jar ->
        var d = Disk(root, jar)
        try {
            d.seedRaw()
            val epoch = displayedEpoch()
            d.files.failClear = true
            val reply = request("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$epoch"}""")
            assertEquals(JsonPrimitive(false), reply["ok"])
            assertEquals(PrivateStorePhase.TRANSITIONING, d.graph.privateBoundary.state.value.phase)
            assertFalse(d.files.isEmpty())
            d.close()
            d = Disk(root, jar)
            val reopened = success("session.privateBoundary").jsonObject
            assertEquals(setOf("phase", "identityEpoch", "requiresConfirmation", "recoveryEligible"), reopened.keys)
            assertEquals(JsonPrimitive(true), reopened["recoveryEligible"], "Interrupted, drained transition must expose explicit recovery")
            assertEquals(JsonPrimitive(true), reopened["requiresConfirmation"])
            assertEquals(PrivateStorePhase.TRANSITIONING, d.graph.privateBoundary.state.value.phase)
            assertNativeDenied(d)
            assertFalse(d.files.isEmpty())
            denied("session.resetPrivateStores", """{"confirmed":true,"identityEpoch":"$epoch"}""")
            reset()
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase)
            assertTrue(d.files.isEmpty())
            assertEquals(JsonNull, success("draft.post.get"))
            assertEquals(JsonNull, success("draft.comment.get", """{"postId":42}"""))
        } finally { d.close() }
    }

    @Test
    fun orphanedRegexCacheCannotBootstrapOwnershipAndConfirmedResetRemovesIt() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            d.db.titleKeywordDao().insertRegexHits(listOf(TitleRegexHitEntity(42)))
            success("session.privateBoundary")
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase,
                "Orphan derived post IDs remain private inventory even when the post cache was cleared")
            reset()
            d.db.useReaderConnection { connection ->
                connection.usePrepared("SELECT COUNT(*) FROM title_regex_hits") { row ->
                    assertTrue(row.step())
                    assertEquals(0L, row.getLong(0))
                }
            }
        } finally { d.close() }
    }

    @Test
    fun deviceGlobalKeywordsAndStickerLibrarySurviveConfirmedPrivateReset() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            val rule = TitleKeywordEntity(TitleKeywordKind.BLOCK_REGEX, "global-filter", 1)
            val sticker = MyStickerEntity("https://fixture.invalid/sticker.png", "global-sticker", 0, 1)
            val repo = StickerRepoEntity("fixture/pack", "main", "pinned", null, 0, 0)
            val folder = StickerFolderEntity("fixture/pack", "art", "sticker.png", null, false, 0)
            d.db.titleKeywordDao().insert(rule)
            d.db.stickerDao().insertMine(listOf(sticker))
            d.db.stickerDao().upsertRepo(repo)
            d.db.stickerDao().upsertFolders(listOf(folder))
            success("session.privateBoundary")
            assertEquals(PrivateStorePhase.READY, d.graph.privateBoundary.state.value.phase)
            d.seedRaw()
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-b"
            success("session.sync")
            reset()
            assertEquals(listOf(rule), d.db.titleKeywordDao().list(TitleKeywordKind.BLOCK_REGEX))
            assertEquals(listOf(sticker), d.db.stickerDao().listMine())
            assertEquals(listOf(repo), d.db.stickerDao().listRepos())
            assertEquals(listOf(folder), d.db.stickerDao().folders("fixture/pack"))
        } finally { d.close() }
    }

    @Test
    fun malformedPrivateReportBytesCannotBeMistakenForEmptyInventory() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            val key = stringPreferencesKey("report_compare_basket")
            d.settingsStore.edit { it[key] = "unparseable-owner-private-fixture" }
            success("session.privateBoundary")
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase,
                "A decoder fallback is not physical emptiness or permission to adopt legacy bytes")
            assertEquals("unparseable-owner-private-fixture", d.settingsStore.data.first()[key])
            reset()
            assertNull(d.settingsStore.data.first()[key])
        } finally { d.close() }
    }

    @Test
    fun schedulerRestartJoinsLateWriterAndRevocationJoinsReplacementBeforeReset() = scenario { root, jar ->
        val d = Disk(root, jar)
        val worker = SupervisorJob()
        val scope = CoroutineScope(worker + Dispatchers.Default)
        val firstEntered = CompletableDeferred<Unit>()
        val firstFinally = CompletableDeferred<Unit>()
        val secondFinally = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondEntered = CompletableDeferred<Unit>()
        val releaseSecond = CompletableDeferred<Unit>()
        val starts = java.util.concurrent.atomic.AtomicInteger()
        try {
            success("session.privateBoundary")
            d.graph.offlineLibrary.download(listOf(42))
            d.loadDetail = { _, _ ->
                val n = starts.incrementAndGet()
                if (n == 1) {
                    firstEntered.complete(Unit)
                    try { awaitCancellation() }
                    finally { withContext(NonCancellable) {
                        firstFinally.complete(Unit)
                        releaseFirst.await()
                        d.settingsStore.edit { it[stringPreferencesKey("scheduler-late-writer-fixture")] = "terminated" }
                    } }
                } else {
                    secondEntered.complete(Unit)
                    try { awaitCancellation() }
                    finally { withContext(NonCancellable) { secondFinally.complete(Unit); releaseSecond.await() } }
                }
            }
            val scheduler = GraphScheduler(scope) { d.graph }.apply { attach(d.graph.privateBoundary) }
            scheduler.startDrain(false)
            withTimeout(3_000) { firstEntered.await() }
            scheduler.startDrain(false, restart = true)
            withTimeout(3_000) { firstFinally.await() }
            assertFalse(secondEntered.isCompleted, "Restart must join noncancellable writer termination")
            assertEquals(1, starts.get())
            releaseFirst.complete(Unit)
            withTimeout(3_000) { secondEntered.await() }
            assertEquals("terminated", d.settingsStore.data.first()[stringPreferencesKey("scheduler-late-writer-fixture")])
            jar.header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=owner-b"
            val switched = CompletableDeferred<JsonObject>()
            val sync = NativeBridge.request("session.sync", "{}") { switched.complete(Json.parseToJsonElement(it).jsonObject) }
            val syncDone = CompletableDeferred<Unit>()
            sync.invokeOnCompletion { syncDone.complete(Unit) }
            withTimeout(3_000) { secondFinally.await() }
            assertFalse(switched.isCompleted, "Reconciliation must wait for replacement writer finally")
            releaseSecond.complete(Unit)
            assertEquals(JsonPrimitive(true), withTimeout(3_000) { switched.await() }["ok"])
            withTimeout(3_000) { syncDone.await() }
            assertNativeDenied(d)
            assertNotNull(d.db.offlineDao().find(42), "Transition must preserve the interrupted queue")
            reset()
            assertNull(d.db.offlineDao().find(42))
        } finally {
            releaseFirst.complete(Unit)
            releaseSecond.complete(Unit)
            worker.cancelAndJoin()
            d.close()
        }
    }

    @Test
    fun mixedHistoryAloneCannotBeAdoptedAsEmptyInstallation() = scenario { root, jar ->
        val d = Disk(root, jar)
        try {
            d.settings.recordRecentBoard("trade")
            success("session.privateBoundary")
            assertEquals(PrivateStorePhase.UNKNOWN, d.graph.privateBoundary.state.value.phase,
                "Existing recent boards are private inventory, not a fresh empty installation")
            assertEquals(listOf("trade"), d.settings.settings.first().recentBoards)
        } finally { d.close() }
    }
}
