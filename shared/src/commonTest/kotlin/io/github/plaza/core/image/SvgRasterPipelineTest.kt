package io.github.plaza.core.image

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.Runnable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlin.coroutines.ContinuationInterceptor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
class SvgRasterPipelineTest {
    @Test
    fun `capture stays on main while rasterization uses the worker dispatcher`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val worker = StandardTestDispatcher(testScheduler, "worker")
        val pipeline = SvgRasterPipeline(main, worker)
        val events = mutableListOf<String>()

        val result = pipeline.render(
            widthPx = 8,
            heightPx = 4,
            capture = {
                assertSame(main, currentCoroutineContext()[ContinuationInterceptor])
                try {
                    events += "capture"
                    byteArrayOf(42)
                } finally {
                    assertSame(main, currentCoroutineContext()[ContinuationInterceptor])
                    events += "cleanup"
                }
            },
            rasterize = { pdf ->
                assertSame(worker, currentCoroutineContext()[ContinuationInterceptor])
                assertEquals(listOf("capture", "cleanup"), events)
                pdf + byteArrayOf(7)
            },
        )

        assertEquals(listOf<Byte>(42, 7), result?.toList())
    }

    @Test
    fun `invalid and over budget dimensions never allocate a capture or bitmap`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val pipeline = SvgRasterPipeline(dispatcher, dispatcher)
        val invalid = listOf(0 to 1, 1 to -1, Int.MAX_VALUE to Int.MAX_VALUE, 4097 to 4096)
        for ((width, height) in invalid) {
            assertNull(pipeline.render(width, height, capture = { error("capture allocated") }, rasterize = { error("bitmap allocated") }))
        }
        assertEquals(listOf<Byte>(1), pipeline.render(4096, 4096, capture = { 1 }, rasterize = { byteArrayOf(it.toByte()) })?.toList())
    }

    @Test
    fun `caller cancellation cleans capture on main without starting rasterization`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val pipeline = SvgRasterPipeline(main, StandardTestDispatcher(testScheduler, "worker"))
        var cleaned = false
        val render = launch {
            pipeline.render(1, 1, capture = {
                try {
                    awaitCancellation()
                } finally {
                    assertSame(main, currentCoroutineContext()[ContinuationInterceptor])
                    cleaned = true
                }
            }, rasterize = { error("cancelled PDF rasterized") })
        }
        runCurrent()
        render.cancelAndJoin()
        assertTrue(cleaned)
        assertTrue(render.isCancelled)
    }

    @Test
    fun `cancelled worker retains gate until native work releases its resources`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val pipeline = SvgRasterPipeline(dispatcher, dispatcher)
        val finishNativeDraw = CompletableDeferred<Unit>()
        var released = false
        var secondCaptured = false
        var firstDelivered = false
        val first = launch {
            pipeline.render(1, 1, capture = { 1 }, rasterize = {
                // A synchronous native draw cannot suspend to observe cancellation. Model that
                // non-cancellable interval without blocking the test scheduler.
                withContext(NonCancellable) {
                    try {
                        finishNativeDraw.await()
                        byteArrayOf(1)
                    } finally {
                        released = true
                    }
                }
            })
            firstDelivered = true
        }
        runCurrent()
        first.cancel()
        val second = async {
            pipeline.render(1, 1, capture = {
                assertTrue(released, "another render started before native resources were released")
                secondCaptured = true
                2
            }, rasterize = { byteArrayOf(2) })
        }
        runCurrent()
        assertFalse(secondCaptured)
        finishNativeDraw.complete(Unit)
        first.join()
        assertEquals(listOf<Byte>(2), second.await()?.toList())
        assertFalse(firstDelivered)
        assertTrue(first.isCancelled)
    }

    @Test
    fun `cancellation during dispatcher handoff never starts queued rasterization`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val queued = mutableListOf<Runnable>()
        val worker = object : kotlinx.coroutines.CoroutineDispatcher() {
            override fun dispatch(context: kotlin.coroutines.CoroutineContext, block: Runnable) {
                queued += block
            }
        }
        val pipeline = SvgRasterPipeline(main, worker)
        var captured = false
        var rasterized = false
        val render = launch {
            pipeline.render(1, 1, capture = {
                captured = true
                1
            }, rasterize = {
                rasterized = true
                byteArrayOf(1)
            })
        }
        runCurrent()
        assertTrue(captured)
        assertFalse(rasterized)
        render.cancel()
        queued.removeAt(0).run()
        runCurrent()
        render.join()
        assertFalse(rasterized)
        assertTrue(render.isCancelled)
    }

    @Test
    fun `null capture skips worker and releases gate for the next render`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val pipeline = SvgRasterPipeline(dispatcher, dispatcher)
        assertNull(pipeline.render<Int>(1, 1, capture = { null }, rasterize = { error("missing PDF rasterized") }))
        assertEquals(listOf<Byte>(2), pipeline.render(1, 1, capture = { 2 }, rasterize = { byteArrayOf(2) })?.toList())
    }

    @Test
    fun `worker deadline expiry discards output and keeps the gate until resources unwind`() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val pipeline = SvgRasterPipeline(dispatcher, dispatcher)
        val finishDraw = CompletableDeferred<Unit>()
        var released = false
        var secondCaptured = false
        val first = async {
            pipeline.render(1, 1, capture = { 1 }, rasterize = {
                withContext(NonCancellable) {
                    try {
                        finishDraw.await()
                        byteArrayOf(1)
                    } finally {
                        released = true
                    }
                }
            })
        }
        runCurrent()
        val second = async {
            pipeline.render(1, 1, capture = {
                assertTrue(released)
                secondCaptured = true
                2
            }, rasterize = { byteArrayOf(2) })
        }
        testScheduler.advanceTimeBy(8_001)
        runCurrent()
        assertFalse(first.isCompleted, "Native work must unwind before the timed-out render completes")
        assertFalse(secondCaptured, "A timed-out worker must not admit another render early")
        finishDraw.complete(Unit)
        runCurrent()
        assertNull(first.await(), "Timed-out output must never be delivered")
        assertEquals(listOf<Byte>(2), second.await()?.toList())
    }

    @Test
    fun `timeout cancels capture and cleans up on main without rasterizing`() = runTest {
        val main = StandardTestDispatcher(testScheduler, "main")
        val pipeline = SvgRasterPipeline(main, StandardTestDispatcher(testScheduler, "worker"))
        var cleaned = false
        val result = async {
            pipeline.render(1, 1, capture = {
                try {
                    awaitCancellation()
                } finally {
                    assertSame(main, currentCoroutineContext()[ContinuationInterceptor])
                    cleaned = true
                }
            }, rasterize = { error("cancelled PDF rasterized") })
        }
        runCurrent()
        testScheduler.advanceTimeBy(8_001)
        runCurrent()
        val finished = result.isCompleted
        result.cancelAndJoin()
        assertTrue(finished, "render must finish after its deadline")
        assertTrue(cleaned)
        assertNull(result.await())
    }
}
