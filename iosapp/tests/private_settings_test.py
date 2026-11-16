#!/usr/bin/env python3
"""Exact native settings dispatch/mapping with real DataStore and boundary sources.

JVM graph/context fixtures supply dependencies; unrelated graph getters throw.
Not NativeBridge callback dispatch, an Apple build, or live-user-store execution.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import signal
import shutil
import zipfile
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--method')
parser.add_argument('--repeat', type=int, default=1)
args = parser.parse_args()
if args.repeat < 1:
    parser.error('--repeat must be positive')
root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(tempfile.mkdtemp(prefix='native-private-settings-', dir=os.environ['TMPDIR']))
print('Artifacts:', out, flush=True)
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
coords = [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test-junit', '2.4.20'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm', '1.11.0'),
    ('org.jetbrains', 'annotations', '23.0.0'),
    ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3'),
]
jars = []
for group, artifact, version in coords:
    found = list((cache / group / artifact / version).rglob('*.jar'))
    if not found:
        raise SystemExit(f'Missing pinned dependency: {group}:{artifact}:{version}')
    jars += found
for group in ['androidx.datastore', 'androidx.paging', 'com.squareup.okio',
              'androidx.collection', 'androidx.compose.runtime', 'org.jetbrains.compose.runtime']:
    jars += list((cache / group).rglob('*.jar'))
for module in ['shared', 'richtext', 'ui', 'designsys']:
    jar = Path(os.environ.get('SETTINGS_REPOSITORY_JARS', str(root))) / f'{module}/build/libs/{module}-jvm.jar'
    if not jar.is_file():
        raise SystemExit(f'Missing real repository jar: {jar}')
    # Concurrent Gradle owners may replace a jar while Kotlin mmap reads it.
    snapshot = out / jar.name
    shutil.copyfile(jar, snapshot)
    digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
    if digest != hashlib.sha256(jar.read_bytes()).hexdigest():
        raise SystemExit(f'Build jar changed during snapshot; retry after build: {jar}')
    with zipfile.ZipFile(snapshot) as archive:
        if archive.testzip() is not None:
            raise SystemExit(f'Invalid build jar snapshot: {jar}')
    jars.append(snapshot)
cp = ':'.join(map(str, jars))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
common = root / 'shared/src/commonMain/kotlin'
# Graph getter signatures come from the actual iOS graph, not guessed interfaces.
graph_source = (root / 'ui/src/commonMain/kotlin/io/github/nodyssey/di/AppContainer.kt').read_text()
imports = {x.rsplit('.', 1)[-1]: x for x in re.findall(r'^import (.*)$', graph_source, re.M)}
props = dict(re.findall(r'val (\w+): ([\w.<>?]+)', graph_source))
# Preserve concrete Apple refinements (notably non-null DohSupport).
apple_source = (main.parent / 'IosAppContainer.kt').read_text()
props.update(dict(re.findall(r'override val (\w+): ([\w.<>?]+)', apple_source)))
source = (main / 'NativeSettings.kt').read_text()
names = sorted(set(re.findall(r'graph\.(\w+)', source)) - {'privateBoundary'})
lines = ['package io.github.nodyssey.ios']
lines += ['import ' + imports.get(props[n].rstrip('?'), props[n].rstrip('?')) for n in names]
lines += ['class IosAppContainer(val values: Map<String, Any>) {']
lines += [f'val {n}: {props[n]} get() = values.getValue("{n}") as {props[n]}' for n in names]
lines += ['val privateBoundary: io.github.nodyssey.data.session.PrivateSessionBoundary get() = values.getValue("privateBoundary") as io.github.nodyssey.data.session.PrivateSessionBoundary', '}']
(out / 'Graph.kt').write_text('\n'.join(lines))
context_match = re.search(r'^internal class NativeContext\(.*$', (main / 'NativeBridge.kt').read_text(), re.M)
if context_match is None:
    raise SystemExit('NativeContext declaration changed; review fixture signature')
context = context_match.group()
(out / 'Context.kt').write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.ios.IosAppContainer
import kotlinx.coroutines.CoroutineScope
import kotlinx.serialization.json.*
''' + context + '''
internal class NativeFailure(val code: String) : Exception()
internal suspend fun NativeContext.releaseNotesRequest(args: JsonObject): JsonElement = error("Unrelated release notes")
''')
(out / 'Runner.kt').write_text('''package io.github.nodyssey.ios.native
import org.junit.runner.*
import org.junit.runner.notification.*
fun main(args: Array<String>) {
    val core = JUnitCore()
    core.addListener(object : RunListener() {
        override fun testStarted(d: Description) { println("START ${d.displayName}") }
        override fun testFinished(d: Description) { println("END ${d.displayName}") }
        override fun testFailure(f: Failure) { println("FAIL ${f.description}\\n${f.trace}") }
    })
    val suites = if (args.isEmpty()) listOf(NativePrivateSettingsJvmTest::class.java,
        NativeSettingsMappingTest::class.java, NativeSettingsPersistenceTest::class.java,
        NativeImageHostSelectionTest::class.java) else listOf(NativePrivateSettingsJvmTest::class.java)
    var failed = false
    for (suite in suites) {
        val result = core.run(if (args.isEmpty()) Request.aClass(suite) else Request.method(suite, args[0]))
        println("RESULT ${suite.simpleName} tests=${result.runCount} failures=${result.failureCount} ignored=${result.ignoreCount}")
        failed = failed || !result.wasSuccessful() || result.runCount == 0 || result.ignoreCount != 0
    }
    check(!failed)
}
''')
sources = [out / f for f in ['Graph.kt', 'Context.kt', 'Runner.kt']]
sources += [main / f for f in ['NativeSettings.kt', 'NativeSettingsMapping.kt']]
sources += [common / 'io/github/nodyssey/data/session' / f for f in [
    'PrivateSessionBoundary.kt', 'SessionWorkBarrier.kt', 'PrivateStoreProvenance.kt', 'PrivatePostRepository.kt']]
sources += [common / 'io/github/nodyssey/data/settings/SettingsRepository.kt']
sources += [root / 'iosapp/tests/fixtures/NativePrivateSettingsJvmTest.kt']
sources += [root / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native' / f for f in [
    'NativeSettingsMappingTest.kt', 'NativeSettingsPersistenceTest.kt', 'NativeImageHostSelectionTest.kt']]
(out / 'sources.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2))
plugin = next((cache / 'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))


def run(command, name, timeout):
    log = out / f'{name}.log'
    with log.open('w') as stream:
        child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            child.wait(timeout=timeout)
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
    print(log.read_text(), end='', flush=True)
    return {'name': name, 'returncode': 124 if timed_out else child.returncode,
            'timeout': timed_out, 'log': str(log)}


compile_result = run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
    '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-opt-in=kotlin.uuid.ExperimentalUuidApi',
    f'-Xfriend-paths={out}/shared-jvm.jar', f'-Xplugin={plugin}',
    '-classpath', cp, '-d', str(out / 'tests.jar')] + list(map(str, sources)), 'compile', 120)
if compile_result['returncode']:
    sys.exit(compile_result['returncode'])
command = [java, f'-Djava.io.tmpdir={out}',
           f'-Dnodyssey.theme.catalog={root}/ui/src/commonMain/kotlin/io/github/nodyssey/ui/settings/theme/ThemePresets.kt',
           f'-Dnodyssey.theme.snapshots={out}/preset-snapshots.json',
           '-cp', str(out / 'tests.jar') + ':' + cp,
           'io.github.nodyssey.ios.native.RunnerKt'] + ([args.method] if args.method else [])
results = [run(command, f'tests-{i + 1}', 45) for i in range(args.repeat)]
(out / 'results.json').write_text(json.dumps(results, indent=2))
sys.exit(next((row['returncode'] for row in results if row['returncode']), 0))
