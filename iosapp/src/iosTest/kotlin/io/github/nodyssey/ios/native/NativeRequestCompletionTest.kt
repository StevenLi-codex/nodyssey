package io.github.nodyssey.ios.native

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSDate
import platform.Foundation.NSRunLoop
import platform.Foundation.NSThread
import platform.Foundation.dateWithTimeIntervalSinceNow
import platform.Foundation.runUntilDate
import platform.Foundation.timeIntervalSinceNow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Actual NativeRequest and real structured Jobs, executable directly by iosSimulatorArm64Test.
 * Pump Main like WebKitSvgRasterizerTest: runBlocking on Main would deadlock the completion ABI.
 * No app graph, upload, fake request handle, or JVM-only test subclass is involved.
 */
class NativeRequestCompletionTest {
    @Test
    fun normalCompletionWaitsForSuspendingFinally() = withFixture { fixture ->
        val releaseFinally = fixture.gate()
        var resultDelivered = false
        var inFinally = false
        var finallyFinished = false
        val job = fixture.scope.launch {
            try {
                resultDelivered = true // A result is deliberately observable before termination.
            } finally {
                inFinally = true
                withContext(NonCancellable) { withTimeout(3_000) { releaseFinally.await() } }
                finallyFinished = true
            }
        }
        val request = NativeRequest(job)
        val callbacks = mutableListOf<Boolean>()
        request.invokeOnCompletion { callbacks += finallyFinished && job.isCompleted }
        pumpUntil("request finally entered") { inFinally }
        assertTrue(resultDelivered)
        flushMain()
        assertFalse(job.isCompleted)
        assertEquals(emptyList(), callbacks, "Result delivery must not release the file lease")
        releaseFinally.complete(Unit)
        pumpUntil("normal completion callback") { callbacks.isNotEmpty() }
        request.cancel()
        flushMain()
        assertEquals(listOf(true), callbacks)
    }

    @Test
    fun cancellationWaitsForFinallyAndStructuredChildCleanup() = cancellationCleanup(parentFirst = true)

    @Test
    fun cancellationWaitsForStructuredChildAndFinallyCleanup() = cancellationCleanup(parentFirst = false)

    private fun cancellationCleanup(parentFirst: Boolean) = withFixture { fixture ->
        val releaseFinally = fixture.gate()
        val releaseChild = fixture.gate()
        var childStarted = false
        var inFinally = false
        var childCleaning = false
        var finallyFinished = false
        var childFinished = false
        lateinit var child: Job
        val job = fixture.scope.launch {
            child = launch {
                try {
                    childStarted = true
                    awaitCancellation()
                } finally {
                    withContext(NonCancellable) {
                        childCleaning = true
                        withTimeout(3_000) { releaseChild.await() }
                        childFinished = true
                    }
                }
            }
            try {
                awaitCancellation()
            } finally {
                withContext(NonCancellable) {
                    inFinally = true
                    withTimeout(3_000) { releaseFinally.await() }
                    finallyFinished = true
                }
            }
        }
        val request = NativeRequest(job)
        val callbacks = mutableListOf<Boolean>()
        request.invokeOnCompletion {
            callbacks += finallyFinished && childFinished && child.isCompleted && job.isCompleted
        }
        pumpUntil("structured child started") { childStarted }
        request.cancel()
        request.cancel()
        pumpUntil("both non-cancellable cleanups entered") { inFinally && childCleaning }
        flushMain()
        assertTrue(job.isCancelled)
        assertFalse(job.isCompleted)
        assertEquals(emptyList(), callbacks, "cancel() returning is not drain")
        if (parentFirst) {
            releaseFinally.complete(Unit)
            pumpUntil("parent finally finished") { finallyFinished }
            assertFalse(childFinished)
        } else {
            releaseChild.complete(Unit)
            pumpUntil("child cleanup finished") { child.isCompleted }
            assertFalse(finallyFinished)
        }
        flushMain()
        assertFalse(job.isCompleted)
        assertEquals(emptyList(), callbacks, "Both cleanups, not just the first, must finish")
        releaseFinally.complete(Unit)
        releaseChild.complete(Unit)
        pumpUntil("cancelled request completion callback") { callbacks.isNotEmpty() }
        request.cancel()
        flushMain()
        assertEquals(listOf(true), callbacks)
    }

    @Test
    fun eachRegistrationRunsExactlyOnce() = withFixture { fixture ->
        val release = fixture.gate()
        val job = fixture.scope.launch { withTimeout(3_000) { release.await() } }
        val request = NativeRequest(job)
        val calls = mutableListOf<Int>()
        // Register the same function twice as well as a distinct function: once per registration,
        // not once per function identity or once per request.
        val sameCallback: () -> Unit = { calls += 1 }
        request.invokeOnCompletion(sameCallback)
        request.invokeOnCompletion(sameCallback)
        request.invokeOnCompletion { calls += 2 }
        flushMain()
        assertEquals(emptyList(), calls)
        release.complete(Unit)
        pumpUntil("all registrations delivered") { calls.size >= 3 }
        request.cancel()
        request.cancel()
        flushMain()
        assertTrue(job.isCompleted)
        assertEquals(listOf(1, 1, 2), calls.sorted())
    }

    @Test
    fun registrationAfterCompletionRunsExactlyOnce() = lateRegistration(cancelled = false)

    @Test
    fun registrationAfterCancelledCompletionRunsExactlyOnce() = lateRegistration(cancelled = true)

    private fun lateRegistration(cancelled: Boolean) = withFixture { fixture ->
        val job = fixture.scope.launch { if (cancelled) awaitCancellation() }
        val request = NativeRequest(job)
        if (cancelled) request.cancel()
        pumpUntil("request terminated before registration") { job.isCompleted }
        val calls = mutableListOf<Boolean>()
        request.invokeOnCompletion { calls += NSThread.isMainThread && job.isCompleted }
        pumpUntil("late registration delivered") { calls.isNotEmpty() }
        request.cancel()
        flushMain()
        assertEquals(listOf(true), calls)
    }

    @Test
    fun mainCallbacksSurviveRequestAndOwnerCancellation() = withFixture { fixture ->
        val started = CompletableDeferred<Unit>()
        val job = fixture.scope.launch(Dispatchers.Default) {
            started.complete(Unit)
            awaitCancellation()
        }
        val request = NativeRequest(job)
        val calls = mutableListOf<Boolean>()
        request.invokeOnCompletion { calls += NSThread.isMainThread && job.isCompleted && job.isCancelled }
        pumpUntil("background request started") { started.isCompleted }
        // Both scopes are dead by the time notification is serviced. A request-owned callback
        // coroutine would never execute; an inline completion handler would run off Main.
        request.cancel()
        fixture.scope.cancel()
        pumpUntil("independent Main callback") { calls.isNotEmpty() }
        pumpUntil("request owner terminated") { fixture.owner.isCompleted }
        request.cancel()
        flushMain()
        assertEquals(listOf(true), calls)
    }

    private class Fixture {
        val owner = SupervisorJob()
        val failures = mutableListOf<Throwable>()
        val scope = CoroutineScope(owner + Dispatchers.Main + CoroutineExceptionHandler { _, failure -> failures += failure })
        private val gates = mutableListOf<CompletableDeferred<Unit>>()

        fun gate(): CompletableDeferred<Unit> = CompletableDeferred<Unit>().also { gates += it }

        fun releaseAll() {
            gates.forEach { it.complete(Unit) }
        }
    }

    private fun withFixture(block: (Fixture) -> Unit) {
        assertTrue(NSThread.isMainThread, "Native tests must pump the actual Main run loop")
        val fixture = Fixture()
        try {
            block(fixture)
        } finally {
            fixture.releaseAll()
            fixture.scope.cancel()
            pumpUntil("fixture cleanup") { fixture.owner.isCompleted }
            flushMain()
            assertEquals(emptyList(), fixture.failures, "Request body or bounded cleanup failed")
        }
    }

    private fun pumpUntil(label: String, predicate: () -> Boolean) {
        val deadline = NSDate.dateWithTimeIntervalSinceNow(5.0)
        while (!predicate() && deadline.timeIntervalSinceNow > 0.0) {
            NSRunLoop.mainRunLoop.runUntilDate(NSDate.dateWithTimeIntervalSinceNow(0.01))
        }
        assertTrue(predicate(), "Timed out waiting for $label")
    }

    private fun flushMain() {
        val marker = Job()
        CoroutineScope(Dispatchers.Main).launch { marker.complete() }
        pumpUntil("Main queue fence") { marker.isCompleted }
    }
}
