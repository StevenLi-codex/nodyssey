@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package io.github.nodyssey.ios.native

import androidx.room.useReaderConnection
import io.github.nodyssey.data.local.*
import io.github.nodyssey.model.*
import kotlinx.coroutines.flow.first
import io.github.nodyssey.ios.*
import io.github.nodyssey.core.NodeSeekSite
import io.github.plaza.core.net.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import java.io.File
import java.nio.file.Files
import org.junit.Test
import kotlin.test.*

/** Complete production bridge/owned graph; real recorded HTML remote/parser. Apple transport is not run. */
class ThreadPreviewJvmTest {
    private class Fixture {
        val main = StandardTestDispatcher()
        val root = Files.createTempDirectory("preview-").toFile()
        val jar = CookieFixture()
        val calls = mutableListOf<HttpRequest>()
        var response: suspend (HttpRequest) -> HttpResponse = { request ->
            HttpResponse(200, request.url, emptyMap(), File(System.getProperty("preview.fixture")).readText())
        }
        val transport = object : HttpTransport {
            override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse {
                calls += request
                return response(request)
            }
        }
        val globals = IosGlobalServices(root, jar, transport)
        val graph = IosAppContainer(globals, File(root, "single-local-v1").apply { mkdirs() }.path)
        val requests = mutableListOf<NativeRequest>()
        val db: NodeSeekDatabase get() = IosAppContainer::class.java.getDeclaredField("databaseDelegate").run {
            isAccessible = true
            (get(graph) as Lazy<*>).value as NodeSeekDatabase
        }
        suspend fun seed() {
            val detail = globals.remotePosts.loadDetail(703863, 1)
            for (page in 3..5) {
                db.postDetailDao().saveThreadPage(703863, "cached window", null, 9, page,
                    listOf(CommentEntity(703863, page, 0, detail.comments.first())), 17L + page, false, true, 23, true)
            }
            // Exceed the normal 60-thread trim limit so accidental repository loads evict rows.
            for (id in 800000L..800060L) {
                db.postDetailDao().saveThreadPage(id, "sentinel $id", null, 1, 1, emptyList(), 10, true)
            }
            db.collectedPostMetaDao().upsert(listOf(CollectedPostMetaEntity(703863, title = "old collected title", listedOrder = 7, updatedAtMillis = 31)))
            db.readMarkDao().upsert(ReadMarkEntity(703863, 37, 99, title = "old read title"))
            db.readingPositionDao().upsert(ReadingPositionEntity(703863, 5, "#83", 41))
            graph.settingsRepository.recordRecentBoard("old-board")
            calls.clear()
        }
        suspend fun rows(): Map<String, List<String>> = db.useReaderConnection { connection ->
            val tables = connection.usePrepared("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") { statement ->
                buildList { while (statement.step()) add(statement.getText(0)) }
            }
            tables.associateWith { table ->
                val columns = connection.usePrepared("PRAGMA table_info(\"$table\")") { statement ->
                    buildList { while (statement.step()) add(statement.getText(1)) }
                }
                connection.usePrepared("SELECT " + columns.joinToString(",") { "quote(\"$it\")" } + " FROM \"$table\"") { statement ->
                    buildList { while (statement.step()) add((0 until statement.getColumnCount()).joinToString("|") { statement.getText(it) }) }.sorted()
                }
            }
        }
        fun disk(): Map<String, String> = root.walkTopDown().filter { it.isFile && !it.name.endsWith("-shm") }.associate {
            it.relativeTo(root).path to java.security.MessageDigest.getInstance("SHA-256").digest(it.readBytes()).joinToString("") { byte -> "%02x".format(byte) }
        }
        suspend fun unchanged(beforeRows: Map<String, List<String>>, beforeDisk: Map<String, String>) {
            assertEquals(beforeRows, rows(), "all real Room table/column SQL values must be unchanged")
            assertEquals(beforeDisk, disk(), "database/WAL/DataStore bytes must be unchanged (SQLite shm lock file excluded)")
            assertEquals(3..5, db.postDetailDao().findDetail(703863)!!.let { it.firstLoadedPage..it.lastLoadedPage })
            assertNull(db.postDetailDao().findDetail(9007199254740993L))
            val evidence = buildJsonObject {
                put("roomTableRows", JsonObject(beforeRows.mapValues { (_, rows) -> JsonArray(rows.map(::JsonPrimitive)) }))
                put("diskSha256BeforeAndAfter", JsonObject(beforeDisk.mapValues { JsonPrimitive(it.value) }))
                put("excludedFile", "SQLite -shm lock file only")
            }
            println("SIDE_EFFECT_PROOF $evidence")
            println("PROOF Room all-table rows + database/WAL/DataStore SHA256 unchanged; cache window=3..5; 62 cached threads retained")
        }
        suspend fun open() {
            Dispatchers.setMain(main)
            fixtureRoot = root
            graph.lifetime.start()
            graph.privateBoundary.reconcile()
            NodysseyApp.fixture = graph
        }
        fun job(request: NativeRequest): Job = NativeRequest::class.java.getDeclaredField("job").run { isAccessible = true; get(request) as Job }
        suspend fun until(condition: () -> Boolean) = withTimeout(5000) {
            while (!condition()) { main.scheduler.runCurrent(); delay(1) }
        }
        suspend fun request(arguments: String = "{\"postId\":703863}"): JsonObject {
            val replies = mutableListOf<String>()
            val request = NativeBridge.request("thread.preview", arguments, replies::add)
            requests += request
            until { job(request).isCompleted }
            return Json.parseToJsonElement(replies.single()).jsonObject
        }
        suspend fun close() {
            requests.forEach { it.cancel() }
            until { requests.all { job(it).isCompleted } }
            graph.close(); globals.close(); root.deleteRecursively()
            Dispatchers.resetMain()
        }
    }

    @Test fun currentProfileIsNotConsultedOrUsedAsPreviewOwner() = runBlocking {
        val f = Fixture()
        try {
            f.open(); f.seed()
            // Deliberately foreign persisted profile: the live jar/admission, not a cached uid,
            // owns this request. No profile API or profile repository may be consulted.
            f.db.profileDao().upsert(SelfProfileEntity(-77, 999999, "foreign cached profile", "", null, null, null, null, null, null, null, null, null, 43))
            val rows = f.rows(); val disk = f.disk()
            val profileDelegate = IosAppContainer::class.java.getDeclaredField("profileRepository\$delegate").run {
                isAccessible = true; get(f.graph) as Lazy<*>
            }
            assertFalse(profileDelegate.isInitialized())
            val data = f.request().getValue("data").jsonObject
            assertEquals(JsonPrimitive(703863L), data["postId"])
            assertEquals(JsonPrimitive(34378L), data.getValue("body").jsonObject["authorUid"])
            assertFalse(profileDelegate.isInitialized())
            assertEquals(listOf(NodeSeekSite.BASE_URL + "/post-703863-1"), f.calls.map { it.url })
            f.unchanged(rows, disk)
        } finally { f.close() }
    }

    @Test fun pendingAuthenticationDeniesPreviewBeforeRemote() = runBlocking {
        val f = Fixture()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        var mutation: Job? = null
        try {
            f.open()
            mutation = CoroutineScope(f.main).launch { f.graph.privateBoundary.sessionMutation { entered.complete(Unit); release.await() } }
            f.until { entered.isCompleted }
            val result = f.request()
            assertEquals(JsonPrimitive("PRIVATE_STORE_RECOVERY_REQUIRED"), result.getValue("error").jsonObject["code"])
            assertTrue(f.calls.isEmpty())
        } finally { release.complete(Unit); f.until { mutation?.isCompleted != false }; f.close() }
    }

    @Test fun installedSiteDriftRejectsBeforeRemoteAndAtReturn() = runBlocking {
        val originalSite = io.github.nodyssey.core.ActiveSite.current
        val otherSite = io.github.nodyssey.core.Site.entries.first { it != originalSite }
        val f = Fixture()
        try {
            f.open()
            // First exercise drift during the recorded response, after the request URL is fixed.
            val html = File(System.getProperty("preview.fixture")).readText()
            f.response = { request ->
                io.github.nodyssey.core.ActiveSite.install(otherSite)
                HttpResponse(200, request.url, emptyMap(), html)
            }
            val result = f.request()
            assertEquals(JsonPrimitive(false), result["ok"], "site changed while remote was suspended must suppress data")
            assertEquals(JsonPrimitive("SESSION_CHANGED"), result.getValue("error").jsonObject["code"])
            assertEquals(listOf(originalSite.origin + "/post-703863-1"), f.calls.map { it.url })
            f.calls.clear()
            val denied = f.request()
            assertEquals(JsonPrimitive("SESSION_CHANGED"), denied.getValue("error").jsonObject["code"])
            assertTrue(f.calls.isEmpty(), "retired site's remote must not be used after an install drift")
        } finally { io.github.nodyssey.core.ActiveSite.install(originalSite); f.close() }
    }

    @Test fun blockedOpeningAndCommentsNeverExportRichNodes() = runBlocking {
        val f = Fixture()
        try {
            f.open(); f.seed()
            val beforeRows = f.rows(); val beforeDisk = f.disk()
            val html = File(System.getProperty("preview.fixture")).readText().replace("class=\"content-item", "class=\"blocked-comment content-item")
            f.response = { HttpResponse(200, it.url, emptyMap(), html) }
            val data = f.request().getValue("data").jsonObject
            val content = listOf(data.getValue("body").jsonObject) + data.getValue("comments").jsonArray.map { it.jsonObject }
            assertTrue(content.all { it["isBlocked"] == JsonPrimitive(true) }, "real parser must see injected server block flags")
            assertTrue(content.all { it.getValue("nodes").jsonArray.isEmpty() && it.getValue("signatureNodes").jsonArray.isEmpty() }, "preview must not export blocked rich content")
            f.unchanged(beforeRows, beforeDisk)
        } finally { f.close() }
    }

    @Test fun successfulPreviewPreservesRealRoomAndDataStoreBytes() = runBlocking {
        val f = Fixture()
        try {
            f.open(); f.seed()
            val rows = f.rows(); val disk = f.disk()
            assertEquals(JsonPrimitive(true), f.request()["ok"])
            val large = f.request("{\"postId\":9007199254740993}")
            assertEquals(JsonPrimitive(9007199254740993L), large.getValue("data").jsonObject["postId"])
            assertEquals(listOf("/post-703863-1", "/post-9007199254740993-1"), f.calls.map { it.url.removePrefix(NodeSeekSite.BASE_URL) })
            f.unchanged(rows, disk)
        } finally { f.close() }
    }

    @Test fun failuresAreSanitizedWithNoOfflineCacheFallbackOrWrites() = runBlocking {
        val f = Fixture()
        try {
            f.open(); f.seed()
            val rows = f.rows(); val disk = f.disk()
            f.response = { throw SiteException(SiteError.Network) }
            val result = f.request()
            assertEquals(JsonPrimitive("NETWORK"), result.getValue("error").jsonObject["code"])
            assertFalse(result.containsKey("data"), "must not return cached body/window on remote failure")
            f.response = { error("secret-cookie=never-export-this https://secret.invalid") }
            val internal = f.request()
            assertEquals(JsonPrimitive("INTERNAL"), internal.getValue("error").jsonObject["code"])
            assertFalse(internal.toString().contains("never-export"))
            f.unchanged(rows, disk)
        } finally { f.close() }
    }

    @Test fun rejectsPaginationAndMalformedInt64BeforeRemote() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            for (args in listOf("{}", "{\"postId\":0}", "{\"postId\":-1}", "{\"postId\":\"703863\"}",
                "{\"postId\":9223372036854775808}", "{\"postId\":703863,\"page\":2}", "{\"postId\":703863,\"page\":1}", "{\"postId\":703863,\"extend\":true}")) {
                assertEquals(JsonPrimitive("INVALID_ARGUMENT"), f.request(args).getValue("error").jsonObject["code"], args)
            }
            assertTrue(f.calls.isEmpty())
        } finally { f.close() }
    }

    @Test fun cancellationJoinsLateRemoteWithoutPublishingOrWrites() = heldPreview("cancel")
    @Test fun identityTransitionJoinsLateRemoteWithoutPublishingOrWrites() = heldPreview("transition")
    @Test fun directCookieDriftSuppressesLateRemoteWithoutWrites() = heldPreview("cookie")
    @Test fun graphRetirementJoinsLateRemoteWithoutPublishingOrWrites() = heldPreview("retire")

    private fun heldPreview(mode: String) = runBlocking {
        val f = Fixture()
        val release = CompletableDeferred<Unit>()
        val entered = CompletableDeferred<Unit>()
        var control: Job? = null
        try {
            f.open(); f.seed()
            val original = f.globals.remotePosts
            val detail = original.loadDetail(703863, 1)
            f.calls.clear()
            val beforeRows = f.rows(); val beforeDisk = f.disk()
            f.globals.remotePosts = object : io.github.nodyssey.data.PostRemoteDataSource by original {
                override suspend fun loadDetail(postId: Long, page: Int): PostDetail = withContext(NonCancellable) {
                    assertEquals(703863L, postId); assertEquals(1, page)
                    entered.complete(Unit)
                    release.await()
                    detail
                }
            }
            val replies = mutableListOf<String>()
            val request = NativeBridge.request("thread.preview", "{\"postId\":703863}", replies::add)
            f.requests += request
            f.until { entered.isCompleted }
            val drained = CompletableDeferred<Unit>()
            request.invokeOnCompletion { drained.complete(Unit) }
            when (mode) {
                "cancel" -> request.cancel()
                "cookie" -> f.jar.header = "session=changed-behind-session-state"
                "transition" -> control = CoroutineScope(f.main).launch {
                    f.graph.privateBoundary.sessionMutation { f.jar.header = "session=new-account" }
                }
                "retire" -> control = CoroutineScope(f.main).launch { f.graph.lifetime.closeAndJoin() }
            }
            f.main.scheduler.runCurrent()
            assertFalse(drained.isCompleted)
            assertTrue(replies.isEmpty())
            if (control != null) assertFalse(control.isCompleted, "transition/retirement must join the admitted late remote")
            release.complete(Unit)
            f.until { f.job(request).isCompleted && (control?.isCompleted != false) && drained.isCompleted }
            assertFalse(replies.any { Json.parseToJsonElement(it).jsonObject.containsKey("data") }, "stale data published: $replies")
            if (mode == "cancel") assertTrue(replies.isEmpty())
            if (mode == "cookie") {
                assertEquals(1, replies.size)
                assertEquals(JsonPrimitive("PRIVATE_STORE_RECOVERY_REQUIRED"), Json.parseToJsonElement(replies.single()).jsonObject.getValue("error").jsonObject["code"])
            }
            // Auth transition has its own documented count-reset persistence; preview itself is
            // checked on SQL rows here, all disk bytes on the non-auth modes.
            assertEquals(beforeRows, f.rows())
            if (mode != "transition") f.unchanged(beforeRows, beforeDisk)
        } finally { release.complete(Unit); control?.join(); f.close() }
    }

    @Test fun closedGraphLifetimeDeniesPreviewBeforeRemote() = runBlocking {
        val f = Fixture()
        try {
            f.open(); f.graph.lifetime.closeAndJoin()
            val result = f.request()
            assertEquals(JsonPrimitive("PRIVATE_STORE_RECOVERY_REQUIRED"), result.getValue("error").jsonObject["code"])
            assertTrue(f.calls.isEmpty())
        } finally { f.close() }
    }

    @Test fun mismatchedRemotePostOrPageIsRejected() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            val original = f.globals.remotePosts
            for (wrongPage in listOf(false, true)) {
                f.globals.remotePosts = object : io.github.nodyssey.data.PostRemoteDataSource by original {
                    override suspend fun loadDetail(postId: Long, page: Int): io.github.nodyssey.model.PostDetail {
                        val detail = original.loadDetail(postId, page)
                        return if (wrongPage) detail.copy(page = 2) else detail.copy(postId = postId + 1)
                    }
                }
                val result = f.request()
                assertEquals(JsonPrimitive(false), result["ok"], "mismatched remote identity cannot publish: $result")
                assertEquals(JsonPrimitive("UNPARSABLE"), result.getValue("error").jsonObject["code"])
                assertFalse(result.containsKey("data"))
            }
        } finally { f.close() }
    }

    @Test fun firstUncachedPreviewReturnsParsedOpeningBody() = runBlocking {
        val f = Fixture()
        try {
            f.open()
            val database = IosAppContainer::class.java.getDeclaredField("databaseDelegate").run { isAccessible = true; get(f.graph) as Lazy<*> }
            assertFalse(database.isInitialized())
            val result = f.request()
            assertEquals(JsonPrimitive(true), result["ok"], "first uncached preview must fetch page1, not UNKNOWN_OPERATION/cache null: $result")
            assertFalse(database.isInitialized(), "first preview must not even open Room/post repository")
            val thread = result.getValue("data").jsonObject
            assertEquals(JsonPrimitive(703863L), thread["postId"])
            assertTrue(thread.getValue("body").jsonObject.getValue("nodes").jsonArray.isNotEmpty())
            assertEquals(JsonPrimitive(1), thread["firstLoadedPage"])
            assertEquals(JsonPrimitive(1), thread["lastLoadedPage"])
            assertEquals(listOf(NodeSeekSite.BASE_URL + "/post-703863-1"), f.calls.map { it.url })
            assertTrue(f.calls.all { it.method == "GET" && it.body == null })
        } finally { f.close() }
    }
}
