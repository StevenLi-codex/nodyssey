package io.github.nodyssey.ios

import io.github.nodyssey.di.AppContainer
import io.github.nodyssey.data.*
import io.github.nodyssey.data.offline.*
import io.github.nodyssey.data.local.*
import io.github.nodyssey.data.settings.*
import io.github.nodyssey.data.session.*
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.net.NodeSeekJsonClient
import io.github.plaza.core.*
import io.github.plaza.core.net.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import platform.Foundation.*
import java.io.File
import java.lang.reflect.Proxy

inline fun <reified T> unused(): T = Proxy.newProxyInstance(T::class.java.classLoader, arrayOf(T::class.java)) { _, method, _ -> error("Unexpected platform call: ${method.name}") } as T
class CookieFixture : SessionCookieStore {
    var header = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=a"
    override fun cookieHeader(url: String) = header
    override fun setCookie(url: String, cookie: String) = error("No live cookies")
    override suspend fun removeAll() { header = "" }
    override fun flush() = Unit
}
internal class IosGlobalServices(val root: File, val jar: CookieFixture) : AppContainer by unused<AppContainer>() {
    val job = SupervisorJob()
    val scope = CoroutineScope(job + Dispatchers.Default)
    override val doh: io.github.nodyssey.data.dns.DohSupport get() = error("DNS is not exercised by the JVM platform fixture")
    override val dispatchers = AppDispatchers()
    override val clock = AppClock.System
    val transport: HttpTransport = unused()
    val htmlClient = SiteHtmlClient(transport, dispatchers, NodeSeekSite.CONFIG)
    val jsonClient = NodeSeekJsonClient(transport, dispatchers)
    val remotePosts: PostRemoteDataSource = unused()
    val database = createNodeSeekDatabase(File(root,"global.db").path)
    val sessionCookies = SessionCookies(NodeSeekSite.CONFIG, jar)
    override val sessionRepository = SessionRepository(sessionCookies, deferPublication = true)
    override val notificationRepository = NotificationRepository(jsonClient)
    override val appVersion = AppVersion("1.0", 1)
    val urlSession = NSURLSession()
    val settingsDataStore = io.github.nodyssey.data.createPreferenceDataStore("settings",scope,root.path)
    val settingsMutex = Mutex()
    val offlineSettings = OfflineSettingsStore(io.github.nodyssey.data.createPreferenceDataStore("offline",scope,root.path))
    val offlineScheduler = object : OfflineWorkScheduler {
        override fun startDrain(wifiOnly: Boolean, restart: Boolean) {}
        override fun ensureMaintenance() {}
    }
    suspend fun close() { job.cancelAndJoin(); database.close() }
}
var fixtureRoot: File = File(".")
fun applicationSupportDirectory() = NSURL(fixtureRoot.path)
fun cachesDirectory() = NSURL(File(fixtureRoot,"cache").path)
fun legacyProvenanceDirectory() = fixtureRoot.path
fun nodysseyImageLoader(context: coil3.PlatformContext, boundary: PrivateSessionBoundary, cachePath: String?, session: () -> NSURLSession) = coil3.ImageLoader(cachePath ?: File(fixtureRoot,"cache/image_cache").path)
class IosOfflineFileStore(private val root: File) : OfflineFileStore {
    fun isEmpty() = !root.exists() || root.listFiles().orEmpty().isEmpty()
    override fun nameOf(url: String) = java.security.MessageDigest.getInstance("SHA-256").digest(url.toByteArray()).joinToString("") { "%02x".format(it) }
    override fun hasStored(url: String) = File(root,nameOf(url)).exists()
    override fun write(name: String, bytes: ByteArray): Long { root.mkdirs(); File(root,name).writeBytes(bytes); return bytes.size.toLong() }
    override fun sweep(keep: Set<String>) { root.listFiles().orEmpty().filter { it.name !in keep }.forEach { it.delete() } }
    override fun clear() { root.deleteRecursively() }
    override fun freeBytes(): Long? = Long.MAX_VALUE
    override fun hasRoomFor(bytes: Long) = true
    companion object { fun of(url: NSURL) = IosOfflineFileStore(File(url.path!!,"offline/images")) }
}
