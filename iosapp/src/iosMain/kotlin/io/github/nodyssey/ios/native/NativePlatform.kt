@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.nodyssey.ios.native

import coil3.BitmapImage
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.toBitmap
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.net.WebKitCookieBridge
import io.github.plaza.core.net.WebUrl
import io.github.plaza.core.toNSData
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okio.FileSystem
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image
import platform.Foundation.NSData
import platform.Foundation.NSHTTPCookie
import platform.Network.nw_interface_type_wifi
import platform.Network.nw_path_monitor_cancel
import platform.Network.nw_path_monitor_create
import platform.Network.nw_path_monitor_set_queue
import platform.Network.nw_path_monitor_set_update_handler
import platform.Network.nw_path_monitor_start
import platform.Network.nw_path_uses_interface_type
import platform.WebKit.WKHTTPCookieStore
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.dispatch_get_main_queue
import kotlin.coroutines.resume

/** No cookies, session fingerprints, proxy credentials or upload tokens cross this ABI. */
class NativePlatformContext internal constructor(
    val baseUrl: String,
    val userAgent: String,
    val usesDefaultUserAgent: Boolean,
    val oneTapSignInPath: String?,
)

/** Main-thread entry points, using exactly the process graph and installed Coil pipeline. */
object NativePlatform {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var browserOwner: NativeBrowserSession? = null
    private val cookieMutation = Mutex()

    fun ready(completion: (NativePlatformContext?, String?) -> Unit): NativeRequest = NativeRequest(
        scope.launch {
            try {
                val graph = NodysseyApp.ensureContainer()
                coroutineContext.ensureActive()
                completion(graph.platformContext(), null)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                coroutineContext.ensureActive()
                completion(null, "PLATFORM_UNAVAILABLE")
            }
        },
    )

    fun isTrustedBrowserUrl(url: String): Boolean =
        url == url.trim() && NodeSeekSite.isTrustedWebViewUrl(url)

    fun isExternalBrowserUrl(url: String): Boolean = nativeImageUrlAllowed(url)

    fun isBrowserUrl(url: String, goal: String): Boolean = isTrustedBrowserUrl(url) ||
        ((goal == "manage" || goal == "telegramBind") && url == url.trim() && NodeSeekSite.isTelegramOAuthUrl(url))

    fun oneTapScript(url: String): String? {
        val expected = WebUrl.parse(NodeSeekSite.BASE_URL)?.host
        val target = WebUrl.parse(url) ?: return null
        val signIn = io.github.nodyssey.core.ActiveSite.current.oneTapSignIn ?: return null
        return signIn.triggerScript
            .takeIf { isTrustedBrowserUrl(url) && target.host == expected && target.path == signIn.path }
    }

    /** Port of ui/login/TurnstileWidget.kt; that function is module-internal, not an exported API. */
    fun turnstileDocument(darkTheme: Boolean): String {
        val sitekey = NodeSeekSite.TURNSTILE_SITEKEY
        require(sitekey.all { it.isLetterOrDigit() || it == '-' || it == '_' })
        val theme = if (darkTheme) "dark" else "light"
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}
            #w{display:flex;justify-content:center;align-items:center;min-height:65px}</style>
            <script>
            function nsTurnstileReady(){try{turnstile.render('#w',{
              sitekey:'$sitekey',theme:'$theme',
              callback:function(t){__nsBridge.post('token',t);},
              'expired-callback':function(){__nsBridge.post('expired','');},
              'timeout-callback':function(){__nsBridge.post('expired','');},
              'error-callback':function(){__nsBridge.post('error','');}
            });}catch(e){__nsBridge.post('error','');}}
            function nsTurnstileReset(){try{turnstile.reset();}catch(e){}}
            </script>
            <script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=nsTurnstileReady" async defer></script>
            </head><body><div id="w"></div></body></html>
        """.trimIndent()
    }

    fun turnstileMessageKind(kind: String, value: String): String = nativeTurnstileMessageKind(kind, value)

    /**
     * Raster display bytes, not an independent URLSession. Coil retains its proxy/header routing,
     * disk-cache strategy and IosSvgDecoder -> WebKit PDF -> worker raster pipeline.
     */
    fun image(url: String, allowMetered: Boolean, completion: (NSData?, String?) -> Unit): NativeRequest = NativeRequest(
        scope.launch {
            try {
                require(nativeImageUrlAllowed(url))
                val graph = NodysseyApp.ensureContainer()
                graph.privateBoundary.reconcile()
                graph.privateBoundary.protect {
                val baseline = graph.sessionRepository.peek()
                val loader = SingletonImageLoader.get(PlatformContext.INSTANCE)
                val wifiOnly = graph.settingsRepository.settings.first().imagesOnWifiOnly
                val deferred = nativeDeferImage(wifiOnly, !wifiOnly || allowMetered || nativeOnWifi(), allowMetered)
                val bytes = withContext(Dispatchers.Default) {
                    // Use the SAME download directory; no duplicate persistent store or guessed file path.
                    val offline = graph.offlineFiles.pathOf(url)
                        ?.let { FileSystem.SYSTEM.read(it) { readByteArray() } }
                    fun cachedBytes(): ByteArray? = loader.diskCache?.let { cache ->
                        cache.openSnapshot(url)?.use { cache.fileSystem.read(it.data) { readByteArray() } }
                    }
                    val memory = if (deferred && offline == null) {
                        loader.memoryCache?.let { cache ->
                            cache.keys.firstOrNull { it.key == url }?.let { cache[it]?.image }
                        }
                    } else {
                        null
                    }
                    // NetworkCachePolicy.DISABLED alone is UNSAFE with the existing NetworkClient:
                    // it does not interpret Coil's only-if-cached header. ByteArrayFetcher cannot network.
                    val source = offline ?: if (deferred) cachedBytes() else null
                    val decoded = memory ?: run {
                        if (deferred && source == null) throw NativeFailure("IMAGE_WIFI_ONLY")
                        val request = ImageRequest.Builder(PlatformContext.INSTANCE).data(source ?: url).build()
                        (loader.execute(request) as? SuccessResult)?.image ?: error("Image unavailable")
                    }
                    coroutineContext.ensureActive()
                    val original = source ?: cachedBytes()
                    // Keep raster originals (including GIF frames); SVG always traverses the installed decoder.
                    if (original != null && nativeRasterBytes(original)) return@withContext original.toNSData()
                    // toBitmap may borrow Coil's cached bitmap. Never close that borrowed object.
                    val bitmap = decoded.toBitmap()
                    try {
                        val encodedImage = Image.makeFromBitmap(bitmap)
                        try {
                            val encoded = encodedImage.encodeToData(EncodedImageFormat.PNG)
                                ?: error("Image unavailable")
                            try {
                                encoded.bytes.toNSData()
                            } finally {
                                encoded.close()
                            }
                        } finally {
                            encodedImage.close()
                        }
                    } finally {
                        if (decoded !is BitmapImage || decoded.bitmap !== bitmap) {
                            bitmap.close()
                        }
                    }
                }
                coroutineContext.ensureActive()
                nativeCheckSession(baseline, graph.sessionRepository.peek())
                completion(bytes, null)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                coroutineContext.ensureActive()
                completion(null, if (failure is NativeFailure && failure.code == "IMAGE_WIFI_ONLY") failure.code else "IMAGE_UNAVAILABLE")
            }
        },
    )

    internal fun claim(session: NativeBrowserSession): Boolean {
        if (browserOwner != null || cookieMutation.isLocked) return false
        browserOwner = session
        return true
    }

    internal fun release(session: NativeBrowserSession) {
        if (browserOwner === session) browserOwner = null
    }

    /** The browser lease also excludes sign-out: no seed/drain can restore deleted cookies. */
    internal suspend fun signOut(graph: IosAppContainer) = withContext(NonCancellable + Dispatchers.Main) {
        cookieMutation.withLock {
            // A live WKWebView can still write cookies after observer.stop(). Only Swift owns
            // stopLoading; refuse until it has begun close, then await that bridge's final drain.
            browserOwner?.awaitClosedForSignOut()
            val store = WKWebsiteDataStore.defaultDataStore().httpCookieStore
            val hosts = NodeSeekSite.CONFIG.sessionUrls.mapNotNull { WebUrl.parse(it)?.host }
            fun isSiteAuth(cookie: NSHTTPCookie): Boolean {
                val domain = cookie.domain.trimStart('.').lowercase()
                return cookie.name in NodeSeekSite.CONFIG.sessionCookieNames &&
                    hosts.any { it == domain || it.endsWith(".$domain") }
            }
            suspend fun cookies(): List<NSHTTPCookie> = suspendCancellableCoroutine { continuation ->
                store.getAllCookies { continuation.resume(it.orEmpty().filterIsInstance<NSHTTPCookie>()) }
            }
            for (cookie in cookies().filter(::isSiteAuth)) {
                suspendCancellableCoroutine { continuation ->
                    store.deleteCookie(cookie) { continuation.resume(Unit) }
                }
            }
            if (cookies().any(::isSiteAuth)) throw NativeFailure("COOKIE_SYNC_FAILED")
            // Existing repository remains the sole Foundation/session authority. Its last action
            // clears Foundation and publishes signed-out, after WebKit removal has completed.
            graph.accountSignOut.signOut()
        }
    }
}

private fun IosAppContainer.platformContext() = NativePlatformContext(
    baseUrl = NodeSeekSite.BASE_URL,
    userAgent = userAgent.value,
    usesDefaultUserAgent = userAgent.isWebViewDefault,
    oneTapSignInPath = io.github.nodyssey.core.ActiveSite.current.oneTapSignIn?.path,
)

/**
 * Owns the existing bridge, not a second cookie implementation. Call close on EVERY dismissal.
 * Starts and teardown live outside Swift tasks so dismissal during seed cannot cancel its last copy.
 * The store must be the same default store installed on the native WKWebView and its OAuth child.
 */
class NativeBrowserSession(cookieStore: WKHTTPCookieStore, private val goal: String) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val bridge = WebKitCookieBridge(cookieStore)
    private var graph: IosAppContainer? = null
    private var baseline: SessionState? = null
    private var opening = false
    private var closing = false
    private var claimed = false
    private var bindingReached = false
    private var bindingPoll: Job? = null
    private val lifecycle = NativeCookieLifecycle(
        seed = { bridge.seed() },
        start = { bridge.start() },
        stop = { bridge.stop() },
        drain = { bridge.drain() },
        publish = {
            val ready = graph
            val before = baseline
            val now = ready?.sessionRepository?.peek()
            ready?.privateBoundary?.finishExternalMutation(
                allowEmptyRebind = before != null && now != null && goal in setOf("login", "oneTapLogin") &&
                    nativeBrowserGoalReached(goal, before, now),
            )
        },
    )

    fun start(completion: (NativePlatformContext?, String?) -> Unit) {
        if (opening || closing) {
            completion(null, "BROWSER_CLOSED")
            return
        }
        opening = true
        scope.launch {
            try {
                require(goal in setOf("login", "oneTapLogin", "challenge", "manage", "telegramBind"))
                val ready = NodysseyApp.ensureContainer()
                if (closing) return@launch
                graph = ready
                baseline = ready.sessionRepository.peek()
                claimed = NativePlatform.claim(this@NativeBrowserSession)
                if (!claimed) {
                    completion(null, "BROWSER_BUSY")
                    return@launch
                }
                ready.privateBoundary.beginExternalMutation()
                if (lifecycle.open() && !closing) {
                    if (goal == "telegramBind") {
                        bindingPoll = scope.launch {
                            while (!closing) {
                                delay(4_000)
                                try {
                                    bindingReached = ready.accountSettingsRepository.telegramBinding().bound
                                } catch (cancelled: CancellationException) {
                                    throw cancelled
                                } catch (_: Exception) {
                                    // A failed poll never means bound. Manual close remains available.
                                }
                                if (bindingReached) break
                            }
                        }
                    }
                    completion(ready.platformContext(), null)
                }
            } catch (cancelled: CancellationException) {
                close { }
                throw cancelled
            } catch (_: Exception) {
                if (!closing) completion(null, "BROWSER_UNAVAILABLE")
                close { }
            }
        }
    }

    /** Reads the mirror only; never publishes a session while a challenge is in progress. */
    fun goalReached(): Boolean {
        if (closing || !claimed) return false
        if (goal == "telegramBind") return bindingReached
        val before = baseline ?: return false
        val now = graph?.sessionRepository?.peek() ?: return false
        return nativeBrowserGoalReached(goal, before, now)
    }

    internal suspend fun awaitClosedForSignOut() {
        if (!closing) throw NativeFailure("BROWSER_BUSY")
        bindingPoll?.cancelAndJoin()
        lifecycle.close()
        NativePlatform.release(this)
    }

    /** Idempotent. Completion is after stop -> drain -> session.sync, never before cookie arrival. */
    fun close(completion: (String?) -> Unit) {
        closing = true
        bindingPoll?.cancel()
        scope.launch {
            var error: String? = null
            try {
                bindingPoll?.cancelAndJoin()
                if (claimed) lifecycle.close()
            } catch (_: Exception) {
                error = "COOKIE_SYNC_FAILED"
            } finally {
                // A failed drain is not a released cookie lease: sign-out must retry/await it.
                if (error == null) NativePlatform.release(this@NativeBrowserSession)
                completion(error)
            }
        }
    }
}

/** One-shot path read. Cancellation tears down the monitor; no persistent background observer. */
private suspend fun nativeOnWifi(): Boolean = suspendCancellableCoroutine { continuation ->
    val monitor = nw_path_monitor_create() ?: run {
        continuation.resume(false)
        return@suspendCancellableCoroutine
    }
    nw_path_monitor_set_update_handler(monitor) { path ->
        val wifi = path != null && nw_path_uses_interface_type(path, nw_interface_type_wifi)
        nw_path_monitor_cancel(monitor)
        if (continuation.isActive) continuation.resume(wifi)
    }
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue())
    continuation.invokeOnCancellation { nw_path_monitor_cancel(monitor) }
    nw_path_monitor_start(monitor)
}

// PLATFORM_FREE_BEGIN
internal fun nativeDeferImage(wifiOnly: Boolean, onWifi: Boolean, allowMetered: Boolean): Boolean =
    wifiOnly && !onWifi && !allowMetered

internal fun nativeRasterBytes(bytes: ByteArray): Boolean {
    if (bytes.size < 12) return false
    fun at(index: Int) = bytes[index].toInt() and 255
    return (at(0) == 137 && bytes.copyOfRange(1, 4).decodeToString() == "PNG") ||
        (at(0) == 255 && at(1) == 216 && at(2) == 255) ||
        bytes.copyOfRange(0, 6).decodeToString() in setOf("GIF87a", "GIF89a") ||
        (bytes.copyOfRange(0, 4).decodeToString() == "RIFF" && bytes.copyOfRange(8, 12).decodeToString() == "WEBP")
}

/** Serialized teardown, including a dismiss that arrives while WebKit is still seeding. */
internal class NativeCookieLifecycle(
    private val seed: suspend () -> Unit,
    private val start: () -> Unit,
    private val stop: () -> Unit,
    private val drain: suspend () -> Unit,
    private val publish: suspend () -> Unit,
) {
    private val gate = Mutex()
    private var closing = false
    private var finished = false

    suspend fun open(): Boolean = gate.withLock {
        if (closing) return@withLock false
        seed()
        if (closing) return@withLock false
        start()
        true
    }

    suspend fun close() {
        closing = true
        gate.withLock {
            if (finished) return@withLock
            stop()
            drain()
            publish()
            finished = true
        }
    }
}

internal fun nativeBrowserGoalReached(goal: String, before: SessionState, now: SessionState): Boolean =
    now.fingerprint != before.fingerprint && when (goal) {
        "login", "oneTapLogin" -> now.isSignedIn
        "challenge" -> now.hasClearance
        else -> false
    }

internal fun nativeTurnstileMessageKind(kind: String, value: String): String = when (kind) {
    "token" -> if (value.isNotBlank()) "token" else "unavailable"
    "expired" -> "expired"
    else -> "unavailable"
}

internal fun nativeImageUrlAllowed(url: String): Boolean {
    if (url != url.trim()) return false
    val parsed = WebUrl.parse(url) ?: return false
    return parsed.host != null && parsed.userInfo == null &&
        (parsed.scheme == "https" || parsed.scheme == "http")
}
