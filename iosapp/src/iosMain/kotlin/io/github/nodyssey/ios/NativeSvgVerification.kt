@file:OptIn(kotlin.experimental.ExperimentalNativeApi::class)

package io.github.nodyssey.ios

import io.github.plaza.core.image.SvgSize
import io.github.plaza.core.toNSData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import platform.Foundation.NSData
import platform.Foundation.NSThread
import kotlin.native.Platform

/**
 * One-shot, fixed-input app-hosted comparison for WebKitSvgRasterizerTest.
 *
 * Kotlin has no Swift-style per-build #if DEBUG in iosMain. The exported facade remains in the
 * framework, but the pinned Kotlin/Native Platform.isDebugBinary guard refuses release execution
 * before creating a coroutine or WebView. It accepts no content, dimensions, URLs, script or paths.
 * This is not a NativeBridge operation, launch argument handler or network/debug endpoint.
 */
class NativeSvgVerification {
    private var job: Job? = null
    private var started = false

    /** Called on Main by XCTest; the actual pipeline starts on Default, exactly as in iosTest. */
    fun start(completion: (NSData?) -> Unit) {
        if (!Platform.isDebugBinary) {
            completion(null)
            return
        }
        check(NSThread.isMainThread)
        check(!started) { "Fixed SVG probe is one-shot" }
        started = true
        job = CoroutineScope(Dispatchers.Default).launch {
            var png: NSData? = null
            try {
                png = WebKitSvgRasterizer().rasterize(
                    """<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
                    <rect width="4" height="4" fill="red"/>
                    <rect y="4" width="4" height="4" fill="blue"/>
                    </svg>""".encodeToByteArray(),
                    SvgSize(8f, 8f),
                    16,
                    16,
                    diagnostic = { println("[svg-raster] $it") },
                )?.toNSData()
            } finally {
                // The real pipeline has already unwound WebKit and worker resource scopes. Report
                // nil even on cancellation, but do not catch/suppress the CancellationException.
                withContext(NonCancellable + Dispatchers.Main) { completion(png) }
            }
        }
    }

    /** XCTest watchdog cleanup only; never extends or replaces the renderer's 8,000 ms policy. */
    fun cancel() {
        if (!Platform.isDebugBinary) return
        check(NSThread.isMainThread)
        job?.cancel()
    }
}
