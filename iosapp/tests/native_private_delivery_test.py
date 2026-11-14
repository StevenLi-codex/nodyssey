#!/usr/bin/env python3
"""Bounded JVM bridge/content + coordinator regression; no network or Apple claims.

Normal mode compiles complete NativeBridge/NativeContent/DTO sources unchanged.
--interval makes nativeDeliver suspend ONLY in a scratch copy and adds a gated
DeliveryProbe.beforePublish call at entry, forcing the dispatch-to-callback
interval without blocking Main. It is scheduling instrumentation, not proof that
an uninstrumented synchronous Main callback suspends. The manifest records hashes.
Graph construction and unused account/settings/supplement domains are fixture seams.
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
CASES = [
    'callbackRetainsLeaseUntilReturn',
    'ownerChangeDuringDispatchSuppressesResult',
    'cancelledObserverDrainsBeforeTransitionAndCanRestart',
    'transitionRevokesObserverAndExplicitRestartReadsAgain',
    'pagingTransitionJoinsDataThenTotalsChild',
    'pagingTransitionJoinsTotalsChildThenData',
]


def bounded(command, out, name, seconds):
    log = out / (name + '.log')
    with log.open('w') as stream:
        child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
            code = 124
    print(log.read_text(), end='', flush=True)
    return {'name': name, 'returncode': code, 'log': str(log), 'deadline_seconds': seconds, 'pid': child.pid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--interval', action='store_true')
    parser.add_argument('--repeat', type=int, default=1)
    args = parser.parse_args()
    if not 1 <= args.repeat <= 20:
        parser.error('repeat must be 1..20')
    out = Path(tempfile.mkdtemp(prefix='native-private-delivery-', dir=os.environ['TMPDIR']))
    print('ARTIFACTS', out, flush=True)
    native = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
    common = ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session'
    sources = [native / f for f in ['NativeBridge.kt', 'NativeContent.kt', 'NativeContentMapping.kt', 'NativeAccountMapping.kt']]
    sources += [common / f for f in ['PrivateSessionBoundary.kt', 'PrivateStoreProvenance.kt', 'SessionWorkBarrier.kt']]
    sources += [ROOT / 'iosapp/tests/delivery/NativePrivateDeliveryTest.kt']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    discovered = re.findall(r'@Test\s+fun (\w+)\(', sources[-1].read_text())
    all_cases = CASES + ['transitionInDispatchToCallbackIntervalSuppressesOldData']
    assert set(discovered) == set(all_cases) and len(discovered) == len(all_cases), discovered
    bridge = (native / 'NativeBridge.kt').read_text()
    if args.interval:
        anchor = 'internal fun nativeDeliver(job: Job, data: JsonElement, completion: (String) -> Unit) {'
        assert bridge.count(anchor) == 1
        instrumented = out / 'NativeBridge.kt'
        instrumented.write_text(bridge.replace(anchor, anchor.replace('internal fun', 'internal suspend fun') + '\n    DeliveryProbe.beforePublish?.invoke()'))
        sources[0] = instrumented
    graph = (ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt').read_text()
    imports = {x.rsplit('.', 1)[-1]: x for x in re.findall(r'^import (.*)$', graph, re.M)}
    props = dict(re.findall(r'override val (\w+): ([\w<>?]+)', graph))
    names = sorted(set(re.findall(r'graph\.(\w+)', bridge + (native / 'NativeContent.kt').read_text())) - {'privateBoundary'})
    lines = ['package io.github.nodyssey.ios']
    lines += ['import ' + imports.get(props[n], props[n]) for n in names]
    lines += ['class IosAppContainer(val values: Map<String, Any>, val privateBoundary: io.github.nodyssey.data.session.PrivateSessionBoundary) {']
    lines += [f'val {n}: {props[n]} get() = values.getValue("{n}") as {props[n]}' for n in names]
    lines += ['}', 'object NodysseyApp { lateinit var fixture: IosAppContainer; suspend fun ensureContainer() = fixture; fun nativeSiteMetadata(): kotlinx.serialization.json.JsonObject = error("Unused public bootstrap; tested in graph integration") }']
    (out / 'Graph.kt').write_text('\n'.join(lines))
    (out / 'UnusedDomains.kt').write_text('''package io.github.nodyssey.ios.native
import kotlinx.serialization.json.*
import kotlinx.coroutines.flow.Flow
internal fun nativeSupersedeAuthentication() { error("Unused auth fixture") }
internal suspend fun NativeContext.accountRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.settingsRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.supplementRequest(op: String, args: JsonObject): JsonElement? = null
internal fun NativeContext.accountObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.settingsObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.supplementObserve(op: String): Flow<JsonElement>? = null
''')
    sources += [out / 'Graph.kt', out / 'UnusedDomains.kt']
    cases = ['transitionInDispatchToCallbackIntervalSuppressesOldData'] if args.interval else CASES
    (out / 'Runner.kt').write_text('''package io.github.nodyssey.ios.native
import org.junit.runner.*
fun main(args: Array<String>) {
    val result = JUnitCore().run(Request.method(NativePrivateDeliveryTest::class.java, args.single()))
    result.failures.forEach { println(it.trace) }
    println("CASE ${args.single()} tests=${result.runCount} failures=${result.failureCount} ignored=${result.ignoreCount}")
    check(result.wasSuccessful() && result.runCount == 1 && result.ignoreCount == 0)
}
''')
    sources += [out / 'Runner.kt']
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    coords = [('org.jetbrains.kotlin', a, '2.4.20') for a in ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-test', 'kotlin-test-junit']]
    coords += [('org.jetbrains.kotlinx', a, '1.11.0') for a in ['kotlinx-coroutines-core-jvm', 'kotlinx-coroutines-test-jvm', 'kotlinx-serialization-core-jvm', 'kotlinx-serialization-json-jvm']]
    coords += [('org.jetbrains.kotlinx', 'kotlinx-datetime-jvm', '0.8.0'), ('org.jetbrains', 'annotations', '23.0.0'), ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3')]
    jars = [p for g,a,v in coords for p in (cache/g/a/v).rglob('*.jar')]
    for group in ['androidx.datastore', 'androidx.paging', 'androidx.collection', 'com.squareup.okio']:
        jars += list((cache/group).rglob('*.jar'))
    jars += [ROOT/f'{m}/build/libs/{m}-jvm.jar' for m in ['shared','richtext']]
    cp = ':'.join(map(str, jars))
    java = str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java')
    plugin = next((cache/'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
    results = [bounded([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-opt-in=kotlin.uuid.ExperimentalUuidApi', f'-Xplugin={plugin}', '-classpath', cp, '-d', str(out/'tests.jar')] + list(map(str, sources)), out, 'compile', 120)]
    if not results[0]['returncode']:
        for repeat in range(args.repeat):
            for case in cases:
                results.append(bounded([java, f'-Djava.io.tmpdir={out}', '-cp', str(out/'tests.jar')+':'+cp, 'io.github.nodyssey.ios.native.RunnerKt', case], out, f'{case}-{repeat+1}', 20))
    manifest = {'mode': 'scratch delivery-entry scheduling gate' if args.interval else 'unchanged production bridge/content', 'source_sha256': hashes, 'cases': cases, 'results': results, 'apple_execution': False, 'live_io': False}
    (out/'manifest.json').write_text(json.dumps(manifest, indent=2))
    print('MANIFEST', out/'manifest.json', flush=True)
    return next((r['returncode'] for r in results if r['returncode']), 0)

if __name__ == '__main__':
    sys.exit(main())
