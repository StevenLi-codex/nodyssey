@file:OptIn(ExperimentalForeignApi::class)

package io.github.nodyssey.ios

import io.github.plaza.core.image.SvgRasterPipeline
import io.github.plaza.core.image.SvgSize
import io.github.plaza.core.toByteArray
import io.github.plaza.core.toNSData
import kotlinx.cinterop.CValue
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.useContents
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.CoreFoundation.CFDataCreateMutable
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFRunLoopGetMain
import platform.CoreFoundation.CFRunLoopPerformBlock
import platform.CoreFoundation.CFRunLoopWakeUp
import platform.CoreFoundation.CFStringCreateWithCString
import platform.CoreFoundation.kCFRunLoopCommonModes
import platform.CoreFoundation.kCFStringEncodingUTF8
import platform.CoreGraphics.CGBitmapContextCreate
import platform.CoreGraphics.CGBitmapContextCreateImage
import platform.CoreGraphics.CGColorSpaceCreateDeviceRGB
import platform.CoreGraphics.CGColorSpaceRelease
import platform.CoreGraphics.CGContextDrawPDFPage
import platform.CoreGraphics.CGContextRelease
import platform.CoreGraphics.CGContextScaleCTM
import platform.CoreGraphics.CGDataProviderCreateWithData
import platform.CoreGraphics.CGDataProviderRelease
import platform.CoreGraphics.CGImageAlphaInfo
import platform.CoreGraphics.CGImageRef
import platform.CoreGraphics.CGImageRelease
import platform.CoreGraphics.CGPDFDocumentCreateWithProvider
import platform.CoreGraphics.CGPDFDocumentGetPage
import platform.CoreGraphics.CGPDFDocumentRelease
import platform.CoreGraphics.CGPDFPageGetBoxRect
import platform.CoreGraphics.CGRect
import platform.CoreGraphics.CGRectMake
import platform.CoreGraphics.kCGPDFMediaBox
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSThread
import platform.Foundation.base64EncodedStringWithOptions
import platform.ImageIO.CGImageDestinationAddImage
import platform.ImageIO.CGImageDestinationCreateWithData
import platform.ImageIO.CGImageDestinationFinalize
import platform.UIKit.UIColor
import platform.UIKit.UIScrollViewContentInsetAdjustmentBehavior
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKPDFConfiguration
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.NSObject
import platform.posix.memcpy
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.resume
import kotlin.math.roundToInt
import kotlin.time.TimeSource

/**
 * Draws an SVG the way the site's own readers see it, by asking WebKit.
 *
 * The alternative on this platform is Skia, and [io.github.plaza.core.image.SvgMarkup] has the whole
 * argument for why it is not enough: it draws no `<text>` and no `<image>`, and there is no binding
 * that could teach it either. WebKit has a full SVG renderer, the device's own font fallback — which
 * is the half that matters for 中文 in a document asking for `Segoe UI` — and it is already in the
 * app, since the sign-in screen is a `WKWebView`.
 *
 * **The document is loaded as an image, not as a page.** `<img src="data:image/svg+xml;…">` puts the
 * SVG in what the spec calls secure static mode: no script runs, no external reference is fetched,
 * no cookie is reachable. That matters because these documents are written by other people — a
 * readme, an attachment, a badge in a post — and the safe way to render a stranger's markup is the
 * mode a browser already refuses to run anything in. It is also why there is a wrapper page at all
 * rather than the markup being handed to `loadData`, which would load it as a document.
 *
 * **The capture is a PDF, not a screenshot.** `takeSnapshot` was the first thing tried and it is the
 * wrong tool: it composites *the screen*, so the web view has to be in the window and on top of it,
 * and what comes back carries whatever the window did to it — the safe-area inset the scroll view
 * applied, the app's own pixels where they overlapped, an image at 1% alpha when the view was faded
 * out to hide it. `createPDF` renders the page itself, offscreen, with the view in no window at all;
 * the page comes back as vector, and rasterising it here is the one place the output size is decided.
 *
 * **One at a time.** The [pipeline] holds this to a single render: a feed scrolling past twenty badges
 * must not have twenty web views alive at once, and each of these is a process.
 */
internal class WebKitSvgRasterizer {
    private val pipeline = SvgRasterPipeline(WebKitMainRunLoop, Dispatchers.Default)

    // WebKit can enter a nested native run loop during initialization. Unlike a GCD Main
    // callback, a CF run-loop block leaves the main dispatch queue available to that loop.
    // This dispatch (and initialization itself) remains inside the pipeline's deadline.
    private object WebKitMainRunLoop : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            val main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, kCFRunLoopCommonModes) { block.run() }
            CFRunLoopWakeUp(main)
        }
    }

    /**
     * Renders [markup] into PNG bytes [widthPx] × [heightPx], or null when it could not be done — a
     * load that never finished, a page WebKit would not print, a PDF that would not rasterise.
     *
     * Null is not an error path so much as the *other* renderer's cue: the caller falls back to Skia,
     * which draws the shapes. A document with less in it than it should have beats no document.
     */
    suspend fun rasterize(
        markup: ByteArray,
        intrinsic: SvgSize,
        widthPx: Int,
        heightPx: Int,
        diagnostic: ((String) -> Unit)? = null,
    ): ByteArray? {
        val trace = RenderTrace(diagnostic)
        return trace.stage("pipeline") {
            pipeline.render(
                widthPx,
                heightPx,
                // WebKit init/load/PDF and finally cleanup all finish on Main. Only immutable PDF data
                // crosses to the worker; even its copy to a Kotlin byte array happens off Main.
                capture = { trace.stage("capture") { renderPdf(markup, intrinsic, trace) } },
                rasterize = { pdf ->
                    trace.stage("worker") {
                        val job = currentCoroutineContext()
                        job.ensureActive()
                        autoreleasepool {
                            if (pdf.length > Int.MAX_VALUE.toULong()) return@autoreleasepool null
                            pdf.toByteArray().toPng(widthPx, heightPx, trace) { job.ensureActive() }
                        }
                    }
                },
            )
        }
    }

    private suspend fun renderPdf(
        markup: ByteArray,
        intrinsic: SvgSize,
        trace: RenderTrace,
    ): NSData? {
        if (!intrinsic.width.isFinite() || !intrinsic.height.isFinite() ||
            intrinsic.width <= 0f || intrinsic.height <= 0f
        ) {
            return null
        }
        // The frame is the document's own size, in points, so that one CSS pixel is one point and the
        // page needs no scaling of its own. Nothing is drawn at this size — the PDF is vector, and the
        // pixels are decided when it is rasterised. The bitmap budget does not bound WebKit layout,
        // embedded image decoding, SVG filters, PDF data or encoder scratch allocations.
        val frame = CGRectMake(0.0, 0.0, intrinsic.width.toDouble(), intrinsic.height.toDouble())
        trace.event("webview.create")
        val webView = offscreenWebView(frame, trace)
        // Held for the length of the render: `navigationDelegate` is a weak reference, and a delegate
        // that only the web view knows about is deallocated before it is ever called back.
        val delegate = LoadDelegate(trace)
        webView.navigationDelegate = delegate
        try {
            val page = wrapperPage(markup, intrinsic)
            trace.event("navigation.request")
            if (!delegate.awaitLoad {
                    val navigation = webView.loadHTMLString(page, baseURL = null)
                    trace.event(if (navigation == null) "navigation.rejected" else "navigation.submitted")
                }
            ) {
                return null
            }
            return printToPdf(webView, frame, trace)
        } finally {
            // Read only at unwind: WKWebView's delegate is weak. Distinguish a lost delegate from
            // a serviced run loop whose WebContent process never called back; do not retain it via
            // a new strong reference across the suspension merely to make this probe pass.
            trace.event(if (webView.navigationDelegate == null) "navigation.delegate_missing" else "navigation.delegate_present")
            webView.stopLoading()
            webView.navigationDelegate = null
            trace.event("webview.cleaned")
        }
    }

    private fun offscreenWebView(frame: CValue<CGRect>, trace: RenderTrace): WKWebView {
        trace.event("configuration.create")
        val configuration =
            WKWebViewConfiguration().apply {
                trace.event("configuration.created")
                // Nothing about this render should outlive it, and nothing about the reader's session
                // belongs in it: a document in secure static mode can reach neither, and a data store
                // of its own makes that true of the web view as well.
                trace.event("datastore.create")
                websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
                trace.event("datastore.assigned")
                defaultWebpagePreferences.allowsContentJavaScript = false
            }
        trace.event("webview.initialize")
        return WKWebView(frame = frame, configuration = configuration).apply {
            trace.event("webview.initialized")
            // An SVG is drawn over whatever is behind it — a card on a dark theme included — so the
            // page, the view and its scroll view all have to stop painting white.
            setOpaque(false)
            backgroundColor = UIColor.clearColor
            scrollView.backgroundColor = UIColor.clearColor
            scrollView.scrollEnabled = false
            scrollView.contentInsetAdjustmentBehavior =
                UIScrollViewContentInsetAdjustmentBehavior.UIScrollViewContentInsetAdjustmentNever
            setUserInteractionEnabled(false)
            trace.event("webview.configured")
        }
    }

    /** The loaded page as a one-page PDF of exactly [frame], or null when WebKit refused. */
    private suspend fun printToPdf(webView: WKWebView, frame: CValue<CGRect>, trace: RenderTrace): NSData? =
        suspendCancellableCoroutine { continuation ->
            val configuration = WKPDFConfiguration().apply { rect = frame }
            trace.event("pdf.request")
            webView.createPDFWithConfiguration(configuration) { data, error ->
                trace.event(if (data == null) "pdf.callback.null" else "pdf.callback.data", error)
                if (continuation.isActive) continuation.resume(data)
            }
        }

    /**
     * The first page of a PDF, drawn into a bitmap of exactly [widthPx] × [heightPx] and encoded.
     *
     * The context starts transparent and nothing fills it, so a document with holes in it keeps them.
     * No flip: a bitmap context and a PDF page both put their origin in the bottom-left corner, and
     * the flip this had at first drew the card upside down.
     */
    private fun ByteArray.toPng(widthPx: Int, heightPx: Int, trace: RenderTrace, checkActive: () -> Unit): ByteArray? =
        usePinned { pinned ->
            checkActive()
            trace.event("pdf.bytes")
            if (isEmpty()) return@usePinned null
            trace.event("pdf.provider")
            val provider = CGDataProviderCreateWithData(null, pinned.addressOf(0), size.toULong(), null)
                ?: return@usePinned null
            trace.event("pdf.document")
            val document = CGPDFDocumentCreateWithProvider(provider)
            CGDataProviderRelease(provider)
            if (document == null) return@usePinned null
            try {
                trace.event("pdf.page")
                val page = CGPDFDocumentGetPage(document, 1u) ?: return@usePinned null
                trace.event("pdf.bounds")
                val box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox)
                val boxWidth = box.useContents { size.width }
                val boxHeight = box.useContents { size.height }
                if (!boxWidth.isFinite() || !boxHeight.isFinite() || boxWidth <= 0.0 || boxHeight <= 0.0) return@usePinned null

                checkActive()
                trace.event("bitmap.colorspace")
                val colorSpace = CGColorSpaceCreateDeviceRGB() ?: return@usePinned null
                trace.event("bitmap.context")
                val context =
                    CGBitmapContextCreate(
                        data = null,
                        width = widthPx.toULong(),
                        height = heightPx.toULong(),
                        bitsPerComponent = 8u,
                        bytesPerRow = widthPx.toULong() * 4u,
                        space = colorSpace,
                        bitmapInfo = CGImageAlphaInfo.kCGImageAlphaPremultipliedLast.value,
                    )
                CGColorSpaceRelease(colorSpace)
                if (context == null) return@usePinned null
                try {
                    trace.event("bitmap.draw")
                    CGContextScaleCTM(context, widthPx / boxWidth, heightPx / boxHeight)
                    CGContextDrawPDFPage(context, page)
                    // Native drawing/encoding cannot be interrupted inside the call. Keep the gate
                    // until finally releases everything, and stop before starting the next stage.
                    checkActive()
                    trace.event("bitmap.image")
                    val image = CGBitmapContextCreateImage(context) ?: return@usePinned null
                    try {
                        encodePng(image, trace, checkActive)
                    } finally {
                        CGImageRelease(image)
                    }
                } finally {
                    CGContextRelease(context)
                }
            } finally {
                CGPDFDocumentRelease(document)
            }
        }

    /** ImageIO encodes a task-local CGImage directly, without creating any UIKit object. */
    private fun encodePng(image: CGImageRef, trace: RenderTrace, checkActive: () -> Unit): ByteArray? {
        checkActive()
        trace.event("png.buffer")
        val data = CFDataCreateMutable(null, 0) ?: return null
        try {
            trace.event("png.type")
            val pngType = CFStringCreateWithCString(null, "public.png", kCFStringEncodingUTF8) ?: return null
            val destination = try {
                trace.event("png.destination")
                CGImageDestinationCreateWithData(data, pngType, 1u, null)
            } finally {
                CFRelease(pngType)
            } ?: return null
            try {
                trace.event("png.add_image")
                CGImageDestinationAddImage(destination, image, null)
                checkActive()
                trace.event("png.finalize")
                if (!CGImageDestinationFinalize(destination)) return null
                checkActive()
                trace.event("png.bytes")
                val length = CFDataGetLength(data)
                if (length <= 0 || length > Int.MAX_VALUE.toLong()) return null
                return ByteArray(length.toInt()).apply {
                    usePinned { pinned -> memcpy(pinned.addressOf(0), CFDataGetBytePtr(data), length.toULong()) }
                }
            } finally {
                CFRelease(destination)
            }
        } finally {
            CFRelease(data)
        }
    }

    /**
     * The page the document is drawn in: the SVG at its own size, on a viewport of that same width.
     *
     * The viewport line is what keeps the two sizes in step. A `WKWebView` lays a page out at 980 CSS
     * pixels wide unless it is told otherwise, and then scales that to the frame; declaring the
     * viewport as the document's own width makes one CSS pixel one point instead, so the image fills
     * the frame the caller built from the same numbers.
     */
    private fun wrapperPage(markup: ByteArray, intrinsic: SvgSize): String {
        val encoded = markup.toNSData().base64EncodedStringWithOptions(0u)
        val cssWidth = intrinsic.width.roundToInt().coerceAtLeast(1)
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="viewport" content="width=$cssWidth">
            <style>html,body{margin:0;padding:0;background:transparent}
            img{width:100%;height:auto;display:block}</style></head>
            <body><img src="data:image/svg+xml;base64,$encoded"></body></html>
        """.trimIndent()
    }

    /**
     * `WKNavigationDelegate` as a Kotlin object, holding the one continuation the load is awaited on.
     *
     * Every callback resumes it, because every one of them ends the wait: a document that failed to
     * load is one this renderer has nothing to draw, and the caller's fallback is the same either way.
     */
    private class LoadDelegate(private val trace: RenderTrace) :
        NSObject(),
        WKNavigationDelegateProtocol {
        private var pending: ((Boolean) -> Unit)? = null

        suspend fun awaitLoad(start: () -> Unit): Boolean =
            suspendCancellableCoroutine { continuation ->
                pending = { finished ->
                    pending = null
                    if (continuation.isActive) continuation.resume(finished)
                }
                start()
            }

        @ObjCSignatureOverride
        override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) {
            trace.event("navigation.provisional")
        }

        @ObjCSignatureOverride
        override fun webView(webView: WKWebView, didCommitNavigation: WKNavigation?) {
            trace.event("navigation.committed")
        }

        @ObjCSignatureOverride
        override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
            trace.event("navigation.finished")
            pending?.invoke(true)
        }

        override fun webViewWebContentProcessDidTerminate(webView: WKWebView) {
            // Observe only: do not change the existing deadline/fallback behavior during diagnosis.
            trace.event("navigation.process_terminated")
        }

        // The two failures share a signature once Objective-C selectors are erased, which is what the
        // annotation is for; they mean the same thing here anyway.
        @ObjCSignatureOverride
        override fun webView(
            webView: WKWebView,
            didFailNavigation: WKNavigation?,
            withError: NSError,
        ) {
            trace.event("navigation.failed", withError)
            pending?.invoke(false)
        }

        @ObjCSignatureOverride
        override fun webView(
            webView: WKWebView,
            didFailProvisionalNavigation: WKNavigation?,
            withError: NSError,
        ) {
            trace.event("navigation.provisional_failed", withError)
            pending?.invoke(false)
        }
    }

    /** Opt-in test diagnostics; never export NSError descriptions/userInfo, URLs or markup. */
    private class RenderTrace(private val diagnostic: ((String) -> Unit)?) {
        private val started = TimeSource.Monotonic.markNow()

        fun event(stage: String, error: NSError? = null) {
            val sink = diagnostic ?: return
            val failure = if (error == null) {
                ""
            } else {
                val domain = when (error.domain) {
                    "WKErrorDomain", "NSURLErrorDomain", "NSCocoaErrorDomain", "NSPOSIXErrorDomain" -> error.domain
                    else -> "other"
                }
                " errorDomain=$domain errorCode=${error.code}"
            }
            sink("stage=$stage main=${NSThread.isMainThread} elapsedMs=${started.elapsedNow().inWholeMilliseconds}$failure")
        }

        suspend fun <T> stage(name: String, block: suspend () -> T?): T? {
            event("$name.enter")
            try {
                return block().also { event(if (it == null) "$name.null" else "$name.ok") }
            } catch (cancelled: TimeoutCancellationException) {
                event("$name.timeout")
                throw cancelled
            } catch (cancelled: CancellationException) {
                event("$name.cancelled")
                throw cancelled
            }
        }
    }
}
