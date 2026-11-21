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
DISPATCH_CASES = [
    'held foreground count coalesces all queued message refresh intents before dispatch',
    'merged interaction publication waits behind older read and newer rows win',
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
    parser.add_argument('--count-refresh-dispatch', action='store_true')
    parser.add_argument('--repeat', type=int, default=1)
    args = parser.parse_args()
    if args.interval and args.count_refresh_dispatch:
        parser.error('--interval and --count-refresh-dispatch are mutually exclusive')
    if not 1 <= args.repeat <= 20:
        parser.error('repeat must be 1..20')
    out = Path(tempfile.mkdtemp(prefix='native-private-delivery-', dir=os.environ['TMPDIR']))
    print('ARTIFACTS', out, flush=True)
    native = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
    common = ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session'
    sources = [native / f for f in ['NativeBridge.kt', 'NativeCountRefreshOwner.kt', 'NativeContent.kt', 'NativeContentMapping.kt', 'NativeAccountMapping.kt']]
    sources += [common / f for f in ['PrivateSessionBoundary.kt', 'PrivateStoreProvenance.kt', 'SessionWorkBarrier.kt']]
    if args.count_refresh_dispatch:
        sources += [
            ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/JsonFields.kt',
            ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/NotificationRepository.kt',
            ROOT / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/MessageRepository.kt',
            ROOT / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native/NativeCountRefreshOwnerTest.kt',
            ROOT / 'iosapp/tests/delivery/NativeCountRefreshDispatchTest.kt',
        ]
    else:
        sources += [ROOT / 'iosapp/tests/delivery/NativePrivateDeliveryTest.kt']
    hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    if args.count_refresh_dispatch:
        discovered = re.findall(r'@Test\s+fun\s+`([^`]+)`\s*\(', sources[-1].read_text())
        assert discovered == DISPATCH_CASES, discovered
        owner_source = sources[-2].read_text()
        owner_cases = re.findall(r'@Test\s+\n?\s*fun\s+`([^`]+)`\s*\(', owner_source)
        assert len(owner_cases) == 6, owner_cases
    else:
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
    graph_path = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt'
    services_path = ROOT / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosGlobalServices.kt'
    app_container_path = ROOT / 'ui/src/commonMain/kotlin/io/github/nodyssey/di/AppContainer.kt'
    graph = graph_path.read_text()
    services = services_path.read_text()
    app_container = app_container_path.read_text()
    import_sources = (graph, services, app_container)
    imports = {}
    for source_text in import_sources:
        imports.update({x.rsplit('.', 1)[-1]: x for x in re.findall(r'^import (.*)$', source_text, re.M) if ' as ' not in x})
    props = dict(re.findall(r'override val (\w+): ([\w<>?]+)', graph))
    interface_props = dict(re.findall(r'^\s*val (\w+): ([\w<>?]+)\s*$', app_container, re.M))
    service_props = dict(re.findall(r'override val (\w+): ([\w<>?]+)', services))
    names = sorted(set(re.findall(r'graph\.(\w+)', bridge + (native / 'NativeContent.kt').read_text())) - {'privateBoundary', 'previewThread'})
    type_by_name = dict(interface_props)
    type_by_name.update(service_props)
    type_by_name.update(props)
    missing = [name for name in names if name not in type_by_name]
    if missing:
        raise SystemExit(f'Cannot derive fixture graph property type from IosAppContainer/AppContainer/IosGlobalServices signatures: {missing}')
    unresolved_imports = sorted({re.sub(r'[<>?]', '', type_by_name[n]) for n in names} - imports.keys() - {'Map', 'String', 'Any'})
    if unresolved_imports:
        raise SystemExit(f'Cannot resolve fixture graph type imports from production declarations: {unresolved_imports}')
    lines = ['package io.github.nodyssey.ios', 'import kotlinx.coroutines.ensureActive']
    lines += ['import ' + imports[re.sub(r'[<>?]', '', type_by_name[n])] for n in names if re.sub(r'[<>?]', '', type_by_name[n]) not in {'Map', 'String', 'Any'}]
    lines += ['class IosAppContainer(val values: Map<String, Any>, val privateBoundary: io.github.nodyssey.data.session.PrivateSessionBoundary) {']
    lines += [f'val {n}: {type_by_name[n]} get() = values.getValue("{n}") as {type_by_name[n]}' for n in names]
    preview = graph[graph.index('    private val previewSite ='):graph.index('    override val postRepository:')]
    lines += [
        'val lifetime = io.github.nodyssey.data.session.PrivateWorkspaceLifetime().also { kotlinx.coroutines.runBlocking { it.start() } }',
        'val remotePosts: io.github.nodyssey.data.PostRemoteDataSource get() = values.getValue("remotePosts") as io.github.nodyssey.data.PostRemoteDataSource',
        preview,
    ]
    hashes[str(graph_path.relative_to(ROOT))] = hashlib.sha256(graph_path.read_bytes()).hexdigest()
    sources += [common / 'PrivateWorkspaceLifetime.kt']
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
    if args.count_refresh_dispatch:
        cases = owner_cases + discovered
        test_classes = {
            **{case: 'NativeCountRefreshOwnerTest' for case in owner_cases},
            **{case: 'NativeCountRefreshDispatchTest' for case in discovered},
        }
    else:
        cases = ['transitionInDispatchToCallbackIntervalSuppressesOldData'] if args.interval else CASES
        test_classes = {case: 'NativePrivateDeliveryTest' for case in cases}
    if args.count_refresh_dispatch:
        class_dispatch = '''
        "NativeCountRefreshOwnerTest" -> NativeCountRefreshOwnerTest::class.java
        "NativeCountRefreshDispatchTest" -> NativeCountRefreshDispatchTest::class.java
        else -> error("unknown test class $className")'''
    else:
        class_dispatch = '''
        else -> NativePrivateDeliveryTest::class.java'''
    (out / 'Runner.kt').write_text(f'''package io.github.nodyssey.ios.native
import org.junit.runner.*
fun main(args: Array<String>) {{
    val caseName = args[0]
    val className = args[1]
    val testClass = when (className) {{{class_dispatch}
    }}
    val result = JUnitCore().run(Request.method(testClass, caseName))
    result.failures.forEach {{ println(it.trace) }}
    println("CASE $caseName tests=${{result.runCount}} failures=${{result.failureCount}} ignored=${{result.ignoreCount}}")
    check(result.wasSuccessful() && result.runCount == 1 && result.ignoreCount == 0)
}}
''')
    sources += [out / 'Runner.kt']
    cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
    coords = [('org.jetbrains.kotlin', a, '2.4.20') for a in ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-test', 'kotlin-test-junit']]
    coords += [('org.jetbrains.kotlinx', a, '1.11.0') for a in ['kotlinx-coroutines-core-jvm', 'kotlinx-coroutines-test-jvm', 'kotlinx-serialization-core-jvm', 'kotlinx-serialization-json-jvm']]
    coords += [('org.jetbrains.kotlinx', 'kotlinx-datetime-jvm', '0.8.0'), ('org.jetbrains', 'annotations', '23.0.0'), ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3')]
    jars = [p for g,a,v in coords for p in (cache/g/a/v).rglob('*.jar')]
    for group in ['androidx.datastore', 'androidx.paging', 'androidx.collection', 'androidx.room', 'androidx.sqlite', 'com.squareup.okio']:
        jars += [p for p in (cache/group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing'])]
    from settings_compile_fixture import repository_jars
    repository_root = ROOT if (ROOT/'shared/build/libs/shared-jvm.jar').exists() else ROOT.parent/'nodyssey-swiftui'
    jars += repository_jars(repository_root, out)
    sources += [common.parent / f for f in ['PostRepository.kt', 'FeedRemoteMediator.kt']]
    # Freeze complete production inputs and avoid classpath jars being rewritten by another owner.
    frozen_sources = []
    for index, source in enumerate(sources):
        frozen = out / 'inputs' / str(index) / source.name
        frozen.parent.mkdir(parents=True, exist_ok=True)
        frozen.write_bytes(source.read_bytes())
        hashes[str(source)] = hashlib.sha256(frozen.read_bytes()).hexdigest()
        frozen_sources.append(frozen)
    sources = frozen_sources
    cp = ':'.join(map(str, jars))
    java = str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java')
    plugin = next((cache/'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
    results = [bounded([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-opt-in=kotlin.uuid.ExperimentalUuidApi', f'-Xplugin={plugin}', '-classpath', cp, '-d', str(out/'tests.jar')] + list(map(str, sources)), out, 'compile', 120)]
    if not results[0]['returncode']:
        for repeat in range(args.repeat):
            for case in cases:
                results.append(bounded([java, f'-Djava.io.tmpdir={out}', '-cp', str(out/'tests.jar')+':'+cp, 'io.github.nodyssey.ios.native.RunnerKt', case, test_classes[case]], out, f'{case}-{repeat+1}', 20))
    manifest = {
        'mode': 'count-refresh-dispatch' if args.count_refresh_dispatch else ('scratch delivery-entry scheduling gate' if args.interval else 'unchanged production bridge/content'),
        'source_sha256': hashes,
        'generated_fixture_sha256': {
            str(p.name): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (out / 'Graph.kt', out / 'UnusedDomains.kt', out / 'Runner.kt')
        },
        'cases': cases,
        'test_classes': test_classes,
        'results': results,
        'graph_fixture': {
            'production_signatures': [
                'ui/src/commonMain/kotlin/io/github/nodyssey/di/AppContainer.kt',
                'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt',
                'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosGlobalServices.kt',
            ],
            'construction': 'generated Graph.kt maps only graph properties read by NativeBridge/NativeContent to explicit fixture values',
            'platform_seams': ['Dispatchers.Main test dispatcher', 'JVM JsonApi fixture', 'JVM cached shared/richtext artifacts'],
            'unused_domain_seam': 'generated UnusedDomains.kt for account/settings/supplement operations not under test',
        },
        'apple_execution': False,
        'live_io': False,
    }
    (out/'manifest.json').write_text(json.dumps(manifest, indent=2))
    print('MANIFEST', out/'manifest.json', flush=True)
    return next((r['returncode'] for r in results if r['returncode']), 0)

if __name__ == '__main__':
    sys.exit(main())
