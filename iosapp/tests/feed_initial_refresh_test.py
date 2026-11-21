#!/usr/bin/env python3
"""Exact feed observer + repository + mediator against real Room/Paging on JVM.

The Apple graph and JSON row mapping are fixture boundaries, not Apple build evidence.
No live HTTP. Cached shared jar supplies unchanged production types/Room generated code.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import hashlib
import json

root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(tempfile.mkdtemp(prefix='feed-initial-refresh-', dir=os.environ['TMPDIR']))
base = Path(os.environ.get('NODYSSEY_CACHED_BUILD', str(root if (root / 'shared/build/libs/shared-jvm.jar').exists() else root.parent / 'nodyssey-swiftui')))
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
for group in ['androidx.room', 'androidx.sqlite', 'androidx.paging', 'androidx.collection', 'androidx.annotation', 'androidx.lifecycle', 'androidx.arch.core', 'androidx.savedstate', 'co.touchlab']:
    jars += [p for p in (cache / group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing'])]
jars += [base / f'{m}/build/libs/{m}-jvm.jar' for m in ['shared', 'richtext']]
bundled = Path(os.environ['TMPDIR']) / 'sqlite-bundled-jvm-2.6.2.jar'
if not bundled.exists():
    subprocess.run(['curl', '-fL', '--connect-timeout', '10', '--max-time', '60', 'https://dl.google.com/dl/android/maven2/androidx/sqlite/sqlite-bundled-jvm/2.6.2/sqlite-bundled-jvm-2.6.2.jar', '-o', str(bundled)], check=True)
jars.append(bundled)
cp = ':'.join(map(str, jars))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
source = (main / 'NativeContent.kt').read_text()
observer = source[source.index('    "feed" -> {', source.index('internal fun NativeContext.contentObserve')):source.index('    "search.feed" ->')]
sessions = source[source.index('/** Main-confined handles'):]
bridge = (main / 'NativeBridge.kt').read_text()
helpers = bridge[bridge.index('internal fun JsonObject.nativeText'):]
(out / 'Dispatch.kt').write_text('''package io.github.nodyssey.ios.native
import androidx.paging.*
import io.github.nodyssey.data.*
import io.github.nodyssey.model.FeedSort
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*
import kotlin.coroutines.CoroutineContext
internal class NativeFailure(val code: String): RuntimeException(code)
internal class Graph(val postRepository: PostRepository)
internal class NativeContext(val graph: Graph)
private val nativePagingSessions = NativePagingSessions()
internal fun NativeContext.fixtureObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when(operation) {
''' + observer + '''else -> null
}
fun nativeFailure(error: Throwable) = """{"error":{"code":"FIXTURE"}}"""
val fixtureRenderedTitles = mutableMapOf<Long, String>()
fun nativeContentJson(post: FeedPost): JsonElement {
    fixtureRenderedTitles[post.summary.postId] = post.summary.title
    return JsonPrimitive(post.summary.postId)
}
fun <T> nativeContentArray(items: List<T>, convert: (T) -> JsonElement) = JsonArray(items.map(convert))
fun nativeContentObject(vararg fields: Pair<String, Any?>): JsonObject = JsonObject(fields.associate { (k,v) -> k to when(v) { null -> JsonNull; is JsonElement -> v; is String -> JsonPrimitive(v); is Int -> JsonPrimitive(v); is Boolean -> JsonPrimitive(v); else -> error("Unsupported $v") } })
''' + sessions.replace('mainContext: CoroutineContext = Dispatchers.Main', 'mainContext: CoroutineContext = kotlin.coroutines.EmptyCoroutineContext') + '\n' + helpers)
shared = root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data'
sources = [out / 'Dispatch.kt', root / 'iosapp/tests/fixtures/FeedInitialRefreshJvmTest.kt', shared / 'PostRepository.kt', shared / 'FeedRemoteMediator.kt', shared / 'session/PrivatePostRepository.kt']
receipt = shared / 'ThreadReactionRead.kt'
if receipt.exists(): sources.append(receipt)
hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [main / 'NativeContent.kt', main / 'NativeBridge.kt', Path(__file__), *jars]}
(out / 'source-hashes.json').write_text(json.dumps(hashes, indent=2))
java = str(Path(os.environ.get('JAVA_HOME', str(Path.home() / '.cache/nodyssey-build/jdk21'))) / 'bin/java')
print('OUTPUT=' + str(out), flush=True)
manifest = {'input_sha256': hashes, 'commands': []}
for name, command in [('compile', [java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-Xfriend-paths=' + str(base / 'shared/build/libs/shared-jvm.jar'), '-classpath', cp, '-d', str(out / 'tests.jar')] + list(map(str, sources))), ('test', [java, '-Djava.io.tmpdir=' + str(out), '-cp', str(out / 'tests.jar') + ':' + cp, 'io.github.nodyssey.ios.native.FeedInitialRefreshJvmTestKt', str(out / 'test.db')])]:
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=150)
    (out / f'{name}.log').write_text(result.stdout)
    manifest['commands'].append({'name': name, 'argv': command, 'exit_code': result.returncode})
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(result.stdout, flush=True)
    if result.returncode: raise SystemExit(result.returncode)
