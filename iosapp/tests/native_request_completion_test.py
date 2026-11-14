#!/usr/bin/env python3
"""Run the concrete Apple NativeRequestCompletionTest on a bounded JVM fixture.

Compiles the NativeRequest class VERBATIM from NativeBridge.kt with real pinned
coroutines; only the surrounding app graph is omitted. The unchanged iosTest
class uses a JVM Foundation-signature/run-loop adapter and queued Main dispatcher.
This is production-class JVM behavior, NOT Kotlin/Native, GCD, export/header, app
linkage, NativeBridge dispatch, or real file-reader verification. No JUnit XML is
written, so this run cannot satisfy the Apple report gate.

Optional scratch-only mutations establish assertion sensitivity; their failures
remain nonzero. They never edit production or the concrete test source.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CASES = (
    'normalCompletionWaitsForSuspendingFinally',
    'cancellationWaitsForFinallyAndStructuredChildCleanup',
    'cancellationWaitsForStructuredChildAndFinallyCleanup',
    'eachRegistrationRunsExactlyOnce',
    'registrationAfterCompletionRunsExactlyOnce',
    'registrationAfterCancelledCompletionRunsExactlyOnce',
    'mainCallbacksSurviveRequestAndOwnerCancellation',
)

FOUNDATION = '''package platform.Foundation
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

// JVM-only platform scheduling fixture, not an emulation of Apple's GCD runtime.
object RunLoopFixture {
    val mainThread: Thread = Thread.currentThread()
    val queue = LinkedBlockingQueue<Runnable>()
}
class NSDate(val deadlineNanos: Long) { companion object }
fun NSDate.Companion.dateWithTimeIntervalSinceNow(seconds: Double): NSDate =
    NSDate(System.nanoTime() + (seconds * 1_000_000_000).toLong())
val NSDate.timeIntervalSinceNow: Double get() = (deadlineNanos - System.nanoTime()) / 1_000_000_000.0
object NSThread { val isMainThread: Boolean get() = Thread.currentThread() === RunLoopFixture.mainThread }
class NSRunLoop { companion object { val mainRunLoop = NSRunLoop() } }
fun NSRunLoop.runUntilDate(date: NSDate) {
    check(NSThread.isMainThread)
    while (true) {
        val remaining = date.deadlineNanos - System.nanoTime()
        if (remaining <= 0) return
        val task = RunLoopFixture.queue.poll(remaining, TimeUnit.NANOSECONDS) ?: return
        task.run()
    }
}
'''

RUNNER = '''@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
package io.github.nodyssey.ios.native
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.resetMain
import org.junit.runner.JUnitCore
import org.junit.runner.Request
import org.junit.runner.Description
import org.junit.runner.notification.Failure
import org.junit.runner.notification.RunListener
import platform.Foundation.RunLoopFixture

fun main(args: Array<String>) {
    check(Thread.currentThread() === RunLoopFixture.mainThread)
    Dispatchers.setMain(object : CoroutineDispatcher() {
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            RunLoopFixture.queue.put(block)
        }
    })
    try {
        val runner = JUnitCore()
        val failed = mutableSetOf<String>()
        runner.addListener(object : RunListener() {
            override fun testStarted(description: Description) { println("RUN ${description.methodName}") }
            override fun testFailure(failure: Failure) { failed += failure.description.methodName }
            override fun testFinished(description: Description) {
                println("CASE_${if (description.methodName in failed) "FAIL" else "PASS"} ${description.methodName}")
            }
        })
        val request = if (args.isEmpty()) Request.aClass(NativeRequestCompletionTest::class.java)
            else Request.method(NativeRequestCompletionTest::class.java, args.single())
        val result = runner.run(request)
        result.failures.forEach { println(it.trace) }
        println("Tests run: ${result.runCount}; failures: ${result.failureCount}; ignored: ${result.ignoreCount}")
        check(result.wasSuccessful() && result.runCount == EXPECTED_COUNT && result.ignoreCount == 0)
        check(RunLoopFixture.queue.isEmpty()) { "Callback work leaked beyond fixture teardown" }
    } finally {
        Dispatchers.resetMain()
    }
}
'''


def bounded_run(command, output, seconds):
    """Timeout/kill only this invocation's process group, never another owner's JVM."""
    with output.open('w') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            returncode = child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
            returncode = 124
    print(output.read_text(), end='', flush=True)
    return returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=CASES)
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--mutation', choices=('early-cancel', 'request-owned-callback', 'inline-callback', 'drop-late', 'duplicate'))
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('--repeat must be between 1 and 20')
    scratch = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='native-request-completion-jvm-', dir=scratch))
    print(f'ARTIFACTS {out}', flush=True)
    source = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native/NativeBridge.kt'
    test = ROOT / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native/NativeRequestCompletionTest.kt'
    text = source.read_text()
    # Exact class slice, not a reimplementation. Fail closed if its boundary moves.
    start = text.index('class NativeRequest internal constructor(')
    end = text.index('internal class NativeContext', start)
    production_class = text[start:end]
    assert production_class.rstrip().endswith('}')
    selected_class = production_class
    if args.mutation:
        original = 'job.invokeOnCompletion { drainCallbacks.launch { completion() } }'
        replacements = {
            'early-cancel': 'job.invokeOnCompletion(onCancelling = true, invokeImmediately = true) { drainCallbacks.launch { completion() } }',
            'request-owned-callback': 'job.invokeOnCompletion { CoroutineScope(job + Dispatchers.Main).launch { completion() } }',
            'inline-callback': 'job.invokeOnCompletion { completion() }',
            'drop-late': 'if (!job.isCompleted) job.invokeOnCompletion { drainCallbacks.launch { completion() } }',
            'duplicate': 'job.invokeOnCompletion { drainCallbacks.launch { completion(); completion() } }',
        }
        assert selected_class.count(original) == 1, 'Mutation target changed; review manually'
        selected_class = selected_class.replace(original, replacements[args.mutation])
    imports = '\n'.join(line for line in text.splitlines() if line.startswith('import kotlinx.coroutines.'))
    sliced = out / 'NativeRequestProductionSlice.kt'
    sliced.write_text('@file:OptIn(kotlinx.coroutines.InternalCoroutinesApi::class)\n'
                      + 'package io.github.nodyssey.ios.native\n' + imports + '\n\n' + selected_class)
    foundation = out / 'FoundationRunLoopFixture.kt'
    foundation.write_text(FOUNDATION)
    runner = out / 'RequestCompletionRunner.kt'
    expected = (args.case,) if args.case else CASES
    runner.write_text(RUNNER.replace('EXPECTED_COUNT', str(len(expected))))
    discovered = re.findall(r'@Test\s+fun (\w+)\(', test.read_text())
    assert set(discovered) == set(CASES) and len(discovered) == len(CASES), discovered
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    jars = []
    for group, artifact, version in [
        ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
        ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
        ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.20'),
        ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
        ('org.jetbrains.kotlinx', 'kotlinx-coroutines-test-jvm', '1.11.0'),
        ('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
        ('org.jetbrains.kotlin', 'kotlin-test-junit', '2.4.20'),
        ('org.jetbrains', 'annotations', '23.0.0'),
        ('junit', 'junit', '4.13.2'),
        ('org.hamcrest', 'hamcrest-core', '1.3'),
    ]:
        found = sorted((cache / group / artifact / version).rglob('*.jar'))
        if not found:
            raise SystemExit(f'Missing pinned dependency: {group}:{artifact}:{version}')
        jars.extend(found)
    cp = os.pathsep.join(map(str, jars))
    java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
    classes = out / 'classes'
    manifest = {
        'fidelity': 'Verbatim production NativeRequest class + unchanged concrete iosTest; JVM Foundation scheduling fixture, not Apple execution',
        'production_source': str(source),
        'production_class_sha256': hashlib.sha256(production_class.encode()).hexdigest(),
        'test_sha256': hashlib.sha256(test.read_bytes()).hexdigest(),
        'mutation': args.mutation,
        'expected_cases': expected,
        'runs': [],
    }
    result = bounded_run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                          '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(classes),
                          str(sliced), str(foundation), str(runner), str(test)], out / 'compile.log', 90)
    manifest['compile_exit'] = result
    if result == 0:
        command = [java, f'-Djava.io.tmpdir={out}', '-cp', str(classes) + os.pathsep + cp,
                   'io.github.nodyssey.ios.native.RequestCompletionRunnerKt']
        if args.case:
            command.append(args.case)
        for iteration in range(args.repeat):
            log = out / f'run-{iteration + 1}.log'
            result = bounded_run(command, log, 60)
            passed = re.findall(r'^CASE_PASS (\w+)$', log.read_text(), re.MULTILINE)
            if result == 0 and sorted(passed) != sorted(expected):
                result = 1
            manifest['runs'].append({'exit': result, 'passed_cases': passed, 'log': str(log)})
            if result:
                break
    manifest['exit'] = result
    manifest['production_class_unchanged_during_run'] = (
        source.read_text().split('class NativeRequest internal constructor(', 1)[1].split('internal class NativeContext', 1)[0]
        == production_class.split('class NativeRequest internal constructor(', 1)[1]
    )
    if not manifest['production_class_unchanged_during_run']:
        manifest['exit'] = result = 1
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'MANIFEST {out / "manifest.json"}', flush=True)
    return result


if __name__ == '__main__':
    sys.exit(main())
