@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.github.nodyssey.ios

import io.github.plaza.core.image.SvgSize
import io.github.plaza.core.toNSData
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import platform.CoreGraphics.CGBitmapContextCreate
import platform.CoreGraphics.CGColorSpaceCreateDeviceRGB
import platform.CoreGraphics.CGColorSpaceRelease
import platform.CoreGraphics.CGContextDrawImage
import platform.CoreGraphics.CGContextRelease
import platform.CoreGraphics.CGImageAlphaInfo
import platform.CoreGraphics.CGImageGetHeight
import platform.CoreGraphics.CGImageGetWidth
import platform.CoreGraphics.CGRectMake
import platform.CoreGraphics.kCGBitmapByteOrder32Big
import platform.Foundation.NSDate
import platform.Foundation.NSRunLoop
import platform.Foundation.NSThread
import platform.Foundation.dateWithTimeIntervalSinceNow
import platform.Foundation.runUntilDate
import platform.Foundation.timeIntervalSinceNow
import platform.UIKit.UIImage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/** Native integration: the actual secure-static WebKit -> PDF -> CoreGraphics -> ImageIO path. */
class WebKitSvgRasterizerTest {
    @Test
    fun `background caller gets a transparent correctly oriented PNG at requested size`() {
        // Native test executables run tests on Main. Pump the run loop instead of blocking WebKit's
        // callbacks with runBlocking; the render itself starts on a real background dispatcher.
        assertTrue(NSThread.isMainThread)
        val parent = SupervisorJob()
        val scope = CoroutineScope(parent + Dispatchers.Default)
        try {
            val render = scope.async {
                WebKitSvgRasterizer().rasterize(
                    """<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8">
                    <rect width="4" height="4" fill="red"/>
                    <rect y="4" width="4" height="4" fill="blue"/>
                    </svg>""".encodeToByteArray(),
                    SvgSize(8f, 8f),
                    16,
                    16,
                )
            }
            val deadline = NSDate.dateWithTimeIntervalSinceNow(15.0)
            while (!render.isCompleted && deadline.timeIntervalSinceNow > 0.0) {
                NSRunLoop.mainRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
            }
            assertTrue(render.isCompleted, "WebKit render did not finish")
            val png = assertNotNull(runBlocking { render.await() })
            assertEquals(listOf<Byte>(-119, 80, 78, 71, 13, 10, 26, 10), png.take(8))
            val image = assertNotNull(UIImage.imageWithData(png.toNSData()))
            val cgImage = assertNotNull(image.CGImage)
            assertEquals(16uL, CGImageGetWidth(cgImage))
            assertEquals(16uL, CGImageGetHeight(cgImage))
            val pixels = ByteArray(16 * 16 * 4)
            pixels.usePinned { pinned ->
                val colors = assertNotNull(CGColorSpaceCreateDeviceRGB())
                val context = try {
                    assertNotNull(CGBitmapContextCreate(pinned.addressOf(0), 16u, 16u, 8u, 64u, colors, CGImageAlphaInfo.kCGImageAlphaPremultipliedLast.value or kCGBitmapByteOrder32Big))
                } finally {
                    CGColorSpaceRelease(colors)
                }
                try {
                    CGContextDrawImage(context, CGRectMake(0.0, 0.0, 16.0, 16.0), cgImage)
                } finally {
                    CGContextRelease(context)
                }
            }
            fun channel(x: Int, y: Int, c: Int) = pixels[(y * 16 + x) * 4 + c].toInt() and 255
            assertEquals(255, channel(2, 2, 0), "top-left red must not be vertically flipped")
            assertEquals(255, channel(2, 13, 2), "bottom-left blue must not be vertically flipped")
            assertEquals(255, channel(2, 2, 3), "red sample must be opaque")
            assertEquals(255, channel(2, 13, 3), "blue sample must be opaque")
            assertEquals(0, channel(13, 2, 3), "transparent pixels must keep their alpha")
            assertEquals(0, channel(13, 13, 3), "transparent pixels must keep their alpha")
        } finally {
            scope.cancel()
            val cleanupDeadline = NSDate.dateWithTimeIntervalSinceNow(3.0)
            while (!parent.isCompleted && cleanupDeadline.timeIntervalSinceNow > 0.0) {
                NSRunLoop.mainRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
            }
            assertTrue(parent.isCompleted, "Main-dispatched WebKit cleanup must finish before the test exits")
        }
    }
}
