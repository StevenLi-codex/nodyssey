#!/usr/bin/env python3
"""Run retained paging.refresh through extracted production iOS Kotlin branches.

Offline JVM probe, not Swift/iOS build evidence. Graph/row mapping and the
Main dispatcher are seams. Receipts exercise the real private repository.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ.get('NODYSSEY_RETAINED_PROBE_OUT', str(Path(os.environ['TMPDIR']) / 'nodyssey-board-retained-refresh-probe')))
OUT.mkdir(parents=True, exist_ok=True)
BUILD = Path(tempfile.mkdtemp(prefix='run-', dir=OUT))
CACHE = Path.home() / '.gradle/caches/modules-2/files-2.1'
BASE = Path(os.environ.get('NODYSSEY_CACHED_BUILD', str(ROOT if (ROOT / 'shared/build/libs/shared-jvm.jar').exists() else ROOT.parent / 'nodyssey-swiftui')))
MAIN = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
SHARED = ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data'
java = Path(os.environ.get('JAVA_HOME', str(Path.home() / '.cache/nodyssey-build/jdk21'))) / 'bin/java'
plugin = next((CACHE / 'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
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
    matches = sorted((CACHE / group / artifact / version).rglob('*.jar'))
    if not matches:
        raise SystemExit(f'Missing cached dependency: {group}:{artifact}:{version}; no installation attempted')
    jars += matches
for group in ['androidx.room', 'androidx.sqlite', 'androidx.paging', 'androidx.collection', 'androidx.annotation', 'androidx.lifecycle', 'androidx.arch.core', 'androidx.savedstate', 'androidx.datastore', 'co.touchlab']:
    jars += sorted(p for p in (CACHE / group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing']))
jars += [BASE / f'{m}/build/libs/{m}-jvm.jar' for m in ['shared', 'richtext']]
jars += [Path(os.environ['TMPDIR']) / 'sqlite-bundled-jvm-2.6.2.jar']
for p in [java, *jars]:
    if not p.exists():
        raise SystemExit(f'Missing cached input: {p}; no installation attempted')
cp = ':'.join(map(str, jars))
frozen = {}
def freeze(path):
    data = path.read_bytes()
    target = BUILD / 'inputs' / path.relative_to(ROOT)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    frozen[str(path)] = {'path': str(target), 'sha256': hashlib.sha256(data).hexdigest()}
    return target

source = freeze(MAIN / 'NativeContent.kt').read_text()
observer = source[source.index('    "feed" -> {', source.index('internal fun NativeContext.contentObserve')):source.index('    "search.feed" ->')]
command = source[source.index('        "paging.access", "paging.refresh", "paging.retry" -> {'):source.index('        "search.local" ->')]
sessions = source[source.index('/** Main-confined handles'):]
bridge = freeze(MAIN / 'NativeBridge.kt').read_text()
helpers = bridge[bridge.index('internal fun JsonObject.nativeText'):]
dispatch = BUILD / 'Dispatch.kt'
dispatch.write_text('''package io.github.nodyssey.ios.native
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
internal fun fixturePresenter(id: String) = nativePagingSessions.get(id)
internal fun fixtureContains(id: String) = nativePagingSessions.contains(id)
internal fun NativeContext.fixtureObserve(operation: String, args: JsonObject): Flow<JsonElement>? = when(operation) {
''' + observer + '''else -> null
}
internal suspend fun NativeContext.fixtureRequest(op: String, a: JsonObject): JsonElement? = when(op) {
''' + command + '''else -> null
}
fun nativeFailure(error: Throwable) = """{"error":{"code":"FIXTURE"}}"""
fun nativeContentJson(post: FeedPost): JsonElement = buildJsonObject {
    put("id", post.summary.postId); put("title", post.summary.title)
}
fun <T> nativeContentArray(items: List<T>, convert: (T) -> JsonElement) = JsonArray(items.map(convert))
fun nativeContentObject(vararg fields: Pair<String, Any?>): JsonObject = JsonObject(fields.associate { (k,v) -> k to when(v) { null -> JsonNull; is JsonElement -> v; is String -> JsonPrimitive(v); is Int -> JsonPrimitive(v); is Boolean -> JsonPrimitive(v); else -> error("Unsupported $v") } })
''' + sessions.replace('mainContext: CoroutineContext = Dispatchers.Main', 'mainContext: CoroutineContext = kotlin.coroutines.EmptyCoroutineContext') + '\n' + helpers)
original_sources = [ROOT / 'iosapp/tests/fixtures/BoardRetainedRefreshJvmTest.kt', SHARED / 'PostRepository.kt', SHARED / 'FeedRemoteMediator.kt']
original_sources += [SHARED / 'session' / name for name in ['PrivatePostRepository.kt', 'PrivateSessionBoundary.kt', 'PrivateStoreProvenance.kt', 'SessionWorkBarrier.kt']]
if (SHARED / 'ThreadReactionRead.kt').exists():
    original_sources.append(SHARED / 'ThreadReactionRead.kt')
sources = [dispatch, *map(freeze, original_sources)]
for p in [Path(__file__), ROOT / 'AGENTS.md', ROOT / 'iosapp/Nodyssey/Native/Foundation/NativeStore.swift']:
    freeze(p)
inputs = [dispatch, plugin, *jars]
manifest = {
    'build_directory': str(BUILD),
    'input_sha256': {**{k: v['sha256'] for k, v in frozen.items()}, **{str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}},
    'frozen_sources': frozen,
    'extraction': {'observer': observer, 'command': command, 'context_replacement': 'Dispatchers.Main -> EmptyCoroutineContext; single runBlocking event loop'},
    'commands': [],
}
(BUILD / 'manifest.json').write_text(json.dumps(manifest, indent=2))
print('OUTPUT=' + str(BUILD), flush=True)
commands = [
    ('compile', [str(java), '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-opt-in=kotlin.uuid.ExperimentalUuidApi', '-Xplugin=' + str(plugin), '-Xfriend-paths=' + str(BASE / 'shared/build/libs/shared-jvm.jar'), '-classpath', cp, '-d', str(BUILD / 'tests.jar'), *map(str, sources)]),
    ('test', [str(java), '-Djava.io.tmpdir=' + str(BUILD), '-cp', str(BUILD / 'tests.jar') + ':' + cp, 'io.github.nodyssey.ios.native.BoardRetainedRefreshJvmTestKt', str(BUILD / 'test.db'), *sys.argv[1:]]),
]
for name, command in commands:
    start = time.monotonic()
    try:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        output, code = result.stdout, result.returncode
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        code = 124
    (BUILD / f'{name}.log').write_text(output)
    manifest['commands'].append({'name': name, 'argv': command, 'exit_code': code, 'elapsed_seconds': time.monotonic() - start})
    (BUILD / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    if name == 'test':
        events = [json.loads(line[6:]) for line in output.splitlines() if line.startswith('TRACE ')]
        (BUILD / 'trace.json').write_text(json.dumps(events, indent=2))
        print(json.dumps({'step': name, 'exit_code': code, 'trace_events': len(events), 'summary': [e for e in events if e['kind'] in ('summary', 'assert_fail')], 'raw_stdout': str(BUILD / f'{name}.log')}, indent=2), flush=True)
    else:
        print(output, flush=True)
        print(f'{name} exit={code}', flush=True)
    if code:
        raise SystemExit(code)
