#!/usr/bin/env python3
"""Replay executed Swift requests through exact NativeAccount + real repositories.

No network: writes are rejected by the harness and represented only by a changed
fixture server. DAO/HTML/JSON are test boundaries; repository cache/growth and
NativeAccount dispatch/mapping are production code. Not Apple bridge linkage.
Run from any directory; optional --swift-log reuses a captured Mac test run.
"""
from pathlib import Path
import argparse
import json
import os
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
here = Path(__file__).resolve().parent
out = Path(os.environ['TMPDIR']) / 'library-repository-regression'
out.mkdir(exist_ok=True)
p = argparse.ArgumentParser()
p.add_argument('--swift-log', type=Path)
args = p.parse_args()
if args.swift_log:
    log = args.swift_log.read_text()
else:
    run = subprocess.run([sys.executable, str(here / 'run-mac-tests.py')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log = run.stdout
    (out / 'swift.log').write_text(log)
    print(log, end='')
    if run.returncode:
        sys.exit(run.returncode)
traces = [json.loads(line.split('LIBRARY_REPOSITORY_TRACE:', 1)[1]) for line in log.splitlines() if 'LIBRARY_REPOSITORY_TRACE:' in line]
assert {'payment', 'uncertainPayment', 'attendance', 'uncertainAttendance'} == {t['scenario'] for t in traces}, 'Missing/extra executed Swift traces'
assert len(traces) == 4, 'Duplicate or missing replay scenarios'
(out / 'traces.json').write_text(json.dumps(traces))
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
jars = []
for group, artifact, version in [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-datetime-jvm', '0.8.0'),
    ('org.jetbrains', 'annotations', '23.0.0'),
]:
    jars += list((cache / group / artifact / version).rglob('*.jar'))
for group in ['com.fleeksoft.ksoup', 'com.fleeksoft.charset', 'com.fleeksoft.io', 'androidx.paging', 'androidx.collection', 'co.touchlab']:
    jars += list((cache / group).rglob('*.jar'))
jars += [root / f'{module}/build/libs/{module}-jvm.jar' for module in ['shared', 'richtext']]
assert all(j.exists() for j in jars), 'Build shared/richtext JVM jars first'
cp = ':'.join(map(str, jars))
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
source = (main / 'NativeAccount.kt').read_text()
graph = (root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt').read_text()
imports = {x.rsplit('.', 1)[-1]: x for x in re.findall(r'^import (.*)$', graph, re.M)}
props = dict(re.findall(r'override val (\w+): ([\w<>?]+)', graph))
names = sorted(set(re.findall(r'graph\.(\w+)', source)))
lines = ['package io.github.nodyssey.ios']
lines += ['import ' + imports.get(props[n], props[n]) for n in names]
lines += ['class IosAppContainer(val values: Map<String, Any>) {']
lines += [f'val {n}: {props[n]} get() = values.getValue("{n}") as {props[n]}' for n in names]
lines += ['}']
(out / 'Graph.kt').write_text('\n'.join(lines))
(out / 'Context.kt').write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.ios.IosAppContainer
import kotlinx.coroutines.CoroutineScope
internal class NativeContext(val graph: IosAppContainer, val scope: CoroutineScope)
internal class NativeFailure(val code: String) : RuntimeException(code)
internal object NativePlatform {
    suspend fun signOut(graph: IosAppContainer): Unit = error("No writes in read-only Library regression")
}
''')
sources = [out / 'Graph.kt', out / 'Context.kt', here / 'RepositoryRegression.kt']
sources += [main / f for f in ['NativeAccount.kt', 'NativeAccountMapping.kt']]
# Compile these repository sources as well: do not rely on an old built jar's cache behavior.
sources += [root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data' / f for f in ['ProfileRepository.kt', 'AssetsRepository.kt']]
# Profile's private parser uses module-internal bootstrap helpers.
sources += [root / 'shared/src/commonMain/kotlin/io/github/nodyssey/core/html' / f for f in ['SiteBootstrap.kt']]
run = subprocess.run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-Xfriend-paths=' + str(root / 'shared/build/libs/shared-jvm.jar'), '-classpath', cp, '-d', str(out / 'tests.jar')] + list(map(str, sources)))
if run.returncode:
    sys.exit(run.returncode)
sys.exit(subprocess.run([java, '-cp', str(out / 'tests.jar') + ':' + cp, 'io.github.nodyssey.ios.native.RepositoryRegressionKt', str(out / 'traces.json'), str(root / 'shared/src/commonTest/resources/fixtures/page-1.html')]).returncode)
