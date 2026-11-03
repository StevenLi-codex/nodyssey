package io.github.plaza.core.image

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The iOS SVG renderer's two stages. Only the captured value crosses dispatchers: capture must
 * dispose of its thread-affine WebKit objects before returning. The gate covers both stages so
 * cancelling a synchronous native draw cannot admit another bitmap before that draw has unwound.
 * Kept platform-free so dispatcher handoff and cancellation are exercised with real coroutines.
 * The eight-second deadline begins after acquiring the gate; synchronous native calls may overrun
 * it, but their result is discarded on cancellation and their resources stay serialized until freed.
 * The pixel ceiling bounds the RGBA bitmap, not PDF input, WebKit or encoder scratch memory.
 */
class SvgRasterPipeline(
    private val main: CoroutineDispatcher,
    private val worker: CoroutineDispatcher,
) {
    private val gate = Mutex()

    suspend fun <Pdf : Any> render(
        widthPx: Int,
        heightPx: Int,
        capture: suspend () -> Pdf?,
        rasterize: suspend (Pdf) -> ByteArray?,
    ): ByteArray? = gate.withLock {
        // 4096 squared RGBA pixels = 64 MiB for the bitmap itself. Long arithmetic also rejects
        // overflowing/malicious dimensions before WebKit or CoreGraphics allocates anything.
        if (widthPx <= 0 || heightPx <= 0 || widthPx.toLong() * heightPx > 16_777_216L) {
            return@withLock null
        }
        withTimeoutOrNull(8_000L) {
            val pdf = withContext(main) { capture() } ?: return@withTimeoutOrNull null
            withContext(worker) { rasterize(pdf) }
        }
    }
}
