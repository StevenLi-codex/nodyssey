#!/usr/bin/env python3
"""Real Room/repository reaction reads and exact native thread dispatch region.

No live I/O. This is a JVM test, not the full session boundary or Apple linkage.
Output contains actual repository-generated bridge results for Swift replay.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[2]
here = Path(__file__).resolve().parent
out = Path(tempfile.mkdtemp(prefix='reaction-repository-', dir=os.environ['TMPDIR']))
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
    jars.extend((cache / group / artifact / version).rglob('*.jar'))
for group in ['androidx.room', 'androidx.sqlite', 'androidx.paging', 'androidx.collection', 'androidx.annotation', 'androidx.lifecycle', 'androidx.arch.core', 'androidx.savedstate', 'co.touchlab']:
    jars.extend(p for p in (cache / group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing']))
jars += [root / f'{m}/build/libs/{m}-jvm.jar' for m in ['shared', 'richtext']]
# JVM bundled driver is not needed by the shipping JVM target; the real Room test needs it.
bundled = Path(os.environ['TMPDIR']) / 'sqlite-bundled-jvm-2.6.2.jar'
if not bundled.exists():
    subprocess.run(['curl', '-fL', '--connect-timeout', '15', '--max-time', '90', 'https://dl.google.com/dl/android/maven2/androidx/sqlite/sqlite-bundled-jvm/2.6.2/sqlite-bundled-jvm-2.6.2.jar', '-o', str(bundled)], check=True, timeout=100)
jars.append(bundled)
cp = ':'.join(map(str, jars))
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
content = (main / 'NativeContent.kt').read_text()
# Exact contiguous production cases: no reimplementation of fallback/provenance.
region = content[content.index('        "thread.get", "thread.config"'):content.index('        "thread.status"')]
bridge = (main / 'NativeBridge.kt').read_text()
helpers = bridge[bridge.index('internal fun JsonObject.nativeText'):]
(out / 'Dispatch.kt').write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.data.PostRepository
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.*
internal class NativeFailure(val code: String): RuntimeException(code)
internal suspend fun fixtureThreadRequest(posts: PostRepository, op: String, a: JsonObject): JsonElement = when(op) {
''' + region + '\nelse -> error("Unsupported fixture operation: $op")\n}\n' + helpers)
sources = [out / 'Dispatch.kt', here / 'ReactionRepositoryRegression.kt', main / 'NativeContentMapping.kt', root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/PostRepository.kt']
# New shared receipt may be placed beside its repository by the shared owner.
receipt = root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/ThreadReactionRead.kt'
if receipt.exists(): sources.append(receipt)
(out / 'source-hashes.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}, indent=2))
print('OUTPUT=' + str(out), flush=True)
subprocess.run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-Xfriend-paths=' + str(root / 'shared/build/libs/shared-jvm.jar'), '-classpath', cp, '-d', str(out / 'tests.jar')] + list(map(str, sources)), check=True, timeout=180)
subprocess.run([java, '-Djava.io.tmpdir=' + str(out), '-cp', str(out / 'tests.jar') + ':' + cp, 'io.github.nodyssey.ios.native.ReactionRepositoryRegressionKt', str(out / 'test.db'), str(out / 'replay.json')] + (['--baseline-only'] if '--baseline-only' in sys.argv else []), check=True, timeout=90)
print('CONTENT_REPOSITORY_REPLAY=' + str(out / 'replay.json'), flush=True)
