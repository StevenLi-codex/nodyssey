#!/usr/bin/env python3
"""Exact native account/bridge sources against real JVM repository jars.
Graph discovery is a fixture; unrelated platform/domain methods throw. This is NOT
an Apple/WebKit implementation test. Requires built shared/richtext JVM jars.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import argparse
import json
import signal
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--open-isolation', action='store_true', help='Legacy RAW composer bypass; intentionally expects obsolete automatic deletion and remains RED.')
parser.add_argument('--graph-integration', action='store_true', help='Production inventory and dispatch regions with real file DataStore/Room; not Apple.')
parser.add_argument('--drain', action='store_true')
parser.add_argument('--open-publication', action='store_true', help='Run the unresolved counts-at-publication regression (expected RED).')
parser.add_argument('--method', help='Run a single named JUnit method.')
parser.add_argument('--repeat', type=int, default=1)
args = parser.parse_args()
if args.repeat < 1:
    parser.error('--repeat must be positive')
if args.open_isolation and args.open_publication:
    parser.error('Select one open gate at a time')


def run_bounded(command, name, deadline):
    """Retain named diagnostics and reap only this invocation's owned process group."""
    log = out / f'{name}.log'
    started = time.monotonic()
    with log.open('w') as stream:
        child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            child.wait(timeout=deadline)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)
    output = log.read_text()
    print(output, end='', flush=True)
    row = {'name': name, 'pid': child.pid, 'returncode': 124 if timed_out else child.returncode,
           'timeout': timed_out, 'deadline_seconds': deadline,
           'seconds': round(time.monotonic() - started, 3), 'log': str(log)}
    (out / f'{name}.json').write_text(json.dumps(row, indent=2))
    if timed_out:
        last = next((line for line in reversed(output.splitlines()) if line.startswith('START ')), name)
        print(f'TIMEOUT {name}: {last}; deadline={deadline}s; owned child reaped; log={log}', flush=True)
    return row


root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(tempfile.mkdtemp(prefix='native-session-security-jvm-', dir=os.environ['TMPDIR']))
print(f'Artifacts: {out}', flush=True)
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
jars = []
for group, artifact, version in [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test-junit', '2.4.20'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-test-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-datetime-jvm', '0.8.0'),
    ('org.jetbrains', 'annotations', '23.0.0'),
    ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3'),
]:
    jars += list((cache / group / artifact / version).rglob('*.jar'))
for group in ['androidx.datastore', 'com.squareup.okio', 'androidx.collection']:
    jars += list((cache / group).rglob('*.jar'))
from settings_compile_fixture import repository_jars
jars += repository_jars(root, out)
if args.graph_integration:
    for group in ['androidx.room', 'androidx.sqlite', 'androidx.paging', 'androidx.annotation', 'androidx.lifecycle', 'androidx.arch.core', 'androidx.savedstate', 'co.touchlab']:
        jars += [p for p in (cache / group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing'])]
    bundled = Path(os.environ['TMPDIR']) / 'sqlite-bundled-jvm-2.6.2.jar'
    if not bundled.exists():
        raise SystemExit('Run reaction-repository-regression.py to provision the real bundled SQLite driver first')
    jars.append(bundled)
cp = ':'.join(map(str, jars))
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
# Only graph construction is replaced: property signatures come from the real shell.
platform = (main / 'NativePlatform.kt').read_text()
platform_region = platform[platform.index('    internal fun claim('):platform.index('\nprivate fun IosAppContainer.platformContext')]
platform_source = '''package io.github.nodyssey.ios.native
import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.net.WebKitCookieBridge
import io.github.plaza.core.net.WebUrl
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import platform.Foundation.NSHTTPCookie
import platform.WebKit.WKHTTPCookieStore
import platform.WebKit.WKWebsiteDataStore
import kotlin.coroutines.resume
'''
platform_source += platform[platform.index('class NativePlatformContext'):platform.index('/** Main-thread entry points')]
platform_source += 'object NativePlatform {\n' + platform[platform.index('    private val scope'):platform.index('    fun ready(')] + platform_region
platform_source += platform[platform.index('private fun IosAppContainer.platformContext'):platform.index('/** One-shot path read.')]
platform_source += platform.split('// PLATFORM_FREE_BEGIN\n')[1]
(out / 'PlatformCore.kt').write_text(platform_source)
source = '\n'.join((main / f).read_text() for f in ['NativeAccount.kt', 'NativeBridge.kt']) + platform_source
graph = (root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt').read_text() + (root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosGlobalServices.kt').read_text()
imports = {x.rsplit('.', 1)[-1]: x for x in re.findall(r'^import (.*)$', graph, re.M)}
props = dict(re.findall(r'override val (\w+): ([\w<>?]+)', graph))
props['privateBoundary'] = 'PrivateSessionBoundary'
names = sorted((set(re.findall(r'graph\.(\w+)', source)) | {'userAgent', 'notificationRepository'}) - {'privateBoundary', 'lifetime', 'workspaceId', 'nativeWorkspaceBoundaryDto'})
lines = ['package io.github.nodyssey.ios']
lines += ['import ' + imports.get(props[n], props[n]) for n in names]
lines += ['class IosAppContainer(val values: Map<String, Any>) {', 'val lifetime = io.github.nodyssey.data.session.PrivateWorkspaceLifetime().also { kotlinx.coroutines.runBlocking { it.start() } }', 'val workspaceId: String? get() = values["workspaceId"] as? String']
lines += [f'val {n}: {props[n]} get() = values.getValue("{n}") as {props[n]}' for n in names]
lines += ['val privateBoundary: io.github.nodyssey.data.session.PrivateSessionBoundary by lazy {\n    val memory = object : androidx.datastore.core.DataStore<androidx.datastore.preferences.core.Preferences> {\n        private val value = kotlinx.coroutines.flow.MutableStateFlow(androidx.datastore.preferences.core.emptyPreferences())\n        override val data: kotlinx.coroutines.flow.Flow<androidx.datastore.preferences.core.Preferences> = value\n        override suspend fun updateData(transform: suspend (androidx.datastore.preferences.core.Preferences) -> androidx.datastore.preferences.core.Preferences): androidx.datastore.preferences.core.Preferences {\n            value.value = transform(value.value)\n            return value.value\n        }\n    }\n    io.github.nodyssey.data.session.PrivateSessionBoundary(\n        io.github.nodyssey.data.session.PrivateStoreProvenance(memory, emptySet()),\n        sessionRepository::privateOwnerProof, emptyList(),\n        beforePublication = { notificationRepository.clearCounts() },\n        publishSession = { sessionRepository.publishReconciled(); Unit },\n    )\n}']
lines += ['}', 'object NodysseyApp { val workspaces = kotlinx.coroutines.flow.MutableStateFlow<IosAppContainer?>(null); var fixture: IosAppContainer get() = checkNotNull(workspaces.value); set(value) { workspaces.value = value }; suspend fun createPrivateWorkspace(confirmed: Boolean, epoch: String): IosAppContainer = error("Workspace integration requires --graph-integration"); suspend fun ensureContainer() = fixture; fun nativeSiteMetadata(): kotlinx.serialization.json.JsonObject = error("Public bootstrap is exercised by --graph-integration only") }']
(out / 'Graph.kt').write_text('\n'.join(lines))
(out / 'UnusedDomains.kt').write_text('''package io.github.nodyssey.ios.native
import kotlinx.serialization.json.*
import kotlinx.coroutines.flow.Flow
internal suspend fun NativeContext.contentRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.settingsRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.supplementRequest(op: String, args: JsonObject): JsonElement? = null
internal fun NativeContext.contentObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.settingsObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.supplementObserve(op: String): Flow<JsonElement>? = null
''')
(out / 'Darwin.kt').write_text('package platform.darwin\nopen class NSObject\n')
sources = [str(out / f) for f in ['Graph.kt', 'UnusedDomains.kt', 'PlatformCore.kt', 'Darwin.kt']]
sources += [str(root / 'iosapp/tests/fixtures' / f) for f in ['SessionFoundationFixture.kt', 'SessionWebKitFixture.kt']]
sources += [str(root / 'shared/src/appleMain/kotlin/io/github/plaza/core/net/WebKitCookieBridge.kt')]
sources += [str(main / f) for f in ['NativeAccount.kt', 'NativeAccountMapping.kt', 'NativeBridge.kt']]
sources += [str(root / 'iosapp/tests/fixtures' / f) for f in ['NativeSessionSecurityJvmTest.kt', 'NativeSessionIsolationOpenTest.kt']]
sources += [str(root / 'iosapp/tests/fixtures/PrivateNativeRequestDrainTest.kt')]
if args.graph_integration:
    from private_graph_fixture import prepare
    sources += prepare(root, out, main)
else:
    from settings_compile_fixture import boundary_sources
    sources += list(map(str, boundary_sources(root, out)))
plugin = next((cache / 'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
compiler_options = ['-Xplugin=' + str(plugin), '-jvm-target', '21', '-Xfriend-paths=' + str(out / 'shared-jvm.jar')]
result = run_bounded([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(out / 'tests.jar')] + compiler_options + sources, 'compile', 90)
if result['returncode']:
    sys.exit(result['returncode'])
runner = out / 'SecurityRunner.java'
runner.write_text('''import org.junit.runner.*;
import org.junit.runner.notification.*;
public class SecurityRunner {
    public static void main(String[] args) throws Exception {
        JUnitCore core = new JUnitCore();
        core.addListener(new RunListener() {
            public void testStarted(Description d) { System.out.println("START " + d.getDisplayName()); }
            public void testFinished(Description d) { System.out.println("END " + d.getDisplayName()); }
            public void testFailure(Failure f) { System.out.println("FAIL " + f.getDescription()); System.out.print(f.getTrace()); }
        });
        Class<?> suite = Class.forName(args[0]);
        Request request = args.length > 1 ? Request.method(suite, args[1]) : Request.aClass(suite);
        Result result = core.run(request);
        System.out.println("RESULT tests=" + result.getRunCount() + " failures=" + result.getFailureCount() + " ignored=" + result.getIgnoreCount());
        System.exit(result.wasSuccessful() ? 0 : 1);
    }
}
''')
result = run_bounded([str(Path(java).with_name('javac')), '-cp', cp, str(runner)], 'compile-runner', 30)
if result['returncode']:
    sys.exit(result['returncode'])
suite = 'NativePrivateGraphIntegrationTest' if args.graph_integration else 'PrivateNativeRequestDrainTest' if args.drain else 'NativeSessionIsolationOpenTest' if args.open_isolation else 'NativeSessionPublicationOpenTest' if args.open_publication else 'NativeSessionSecurityJvmTest'
method = args.method
command = [java, f'-Djava.io.tmpdir={out}', '-cp', str(out) + ':' + str(out / 'tests.jar') + ':' + cp, 'SecurityRunner', 'io.github.nodyssey.ios.native.' + suite]
if method:
    command.append(method)
results = [run_bounded(command, f'{suite}-{method or "ALL"}-{i + 1}', 30) for i in range(args.repeat)]
(out / 'results.json').write_text(json.dumps(results, indent=2))
print(f'Suites: {len(results)}; passed: {sum(row["returncode"] == 0 for row in results)}; artifacts: {out}', flush=True)
sys.exit(next((row['returncode'] for row in results if row['returncode']), 0))
