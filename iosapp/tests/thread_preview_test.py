#!/usr/bin/env python3
"""Offline JVM: complete native bridge + owned iOS graph, real Room and HTML parser.
Apple Foundation/Coil/network and global service construction are explicit fixtures.
No live traffic, Gradle build, or Apple linkage is claimed.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import sys
from settings_compile_fixture import repository_jars, compiler_options, run, junit_runner, output_directory

root = Path(__file__).resolve().parents[2]
out = output_directory('thread-preview')
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
java = str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java')
base = root if (root / 'shared/build/libs/shared-jvm.jar').exists() else root.parent / 'nodyssey-swiftui'
jars = repository_jars(base, out)
for group, artifacts, version in [
    ('org.jetbrains.kotlin', ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-test', 'kotlin-test-junit'], '2.4.20'),
    ('org.jetbrains.kotlinx', ['kotlinx-coroutines-core-jvm', 'kotlinx-coroutines-test-jvm', 'kotlinx-serialization-core-jvm', 'kotlinx-serialization-json-jvm'], '1.11.0'),
    ('org.jetbrains.kotlinx', ['kotlinx-datetime-jvm'], '0.8.0'),
    ('org.jetbrains', ['annotations'], '23.0.0'),
    ('junit', ['junit'], '4.13.2'), ('org.hamcrest', ['hamcrest-core'], '1.3'),
]:
    for artifact in artifacts:
        matches = sorted((cache / group / artifact / version).rglob('*.jar'))
        if not matches:
            raise SystemExit(f'Missing cached {group}:{artifact}:{version}; no install attempted')
        jars += matches
for group in ['androidx.datastore', 'com.squareup.okio', 'androidx.collection', 'androidx.room', 'androidx.sqlite', 'androidx.paging', 'androidx.annotation', 'androidx.lifecycle', 'androidx.arch.core', 'androidx.savedstate', 'co.touchlab', 'com.fleeksoft.ksoup', 'com.fleeksoft.io', 'com.fleeksoft.charset', 'com.fleeksoft']:
    jars += [p for p in (cache / group).rglob('*.jar') if not any(x in str(p) for x in ['compiler', 'gradle-plugin', 'testing'])]
jars += [Path(os.environ['TMPDIR']) / 'sqlite-bundled-jvm-2.6.2.jar']
assert all(p.is_file() for p in jars)
cp = ':'.join(map(str, jars))
native = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
graph = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/IosAppContainer.kt'
text = graph.read_text()
body = text[text.index('/** Immutable, owned'):]
imports = [line for line in text.splitlines() if line.startswith('import ') and re.search(r'\b' + re.escape(line.rsplit('.', 1)[-1]) + r'\b', body)]
(out / 'OwnedGraph.kt').write_text('package io.github.nodyssey.ios\n' + '\n'.join(imports) + '\n' + body)
sources = [out / 'OwnedGraph.kt', graph.with_name('IosAppCacheStore.kt'), root / 'iosapp/tests/fixtures/OwnedWorkspacePlatform.kt']
session = root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session'
sources += list(session.glob('Private*.kt')) + [session / 'SessionWorkBarrier.kt', session.parent / 'settings/WorkspaceSettingsDataStore.kt']
# Reuse the existing explicit platform facades, not its success tests or graph substitutes.
scaffold_path = root / 'iosapp/tests/owned_workspace_graph_test.py'
scaffold = scaffold_path.read_text()
exec(scaffold[scaffold.index('# JVM factory'):scaffold.index('plugin =')])
(out / 'UnusedDomains.kt').write_text('''package io.github.nodyssey.ios.native
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.*
internal fun nativeSupersedeAuthentication(): Nothing = error("unused authentication")
internal suspend fun NativeContext.accountRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.settingsRequest(op: String, args: JsonObject): JsonElement? = null
internal suspend fun NativeContext.supplementRequest(op: String, args: JsonObject): JsonElement? = null
internal fun NativeContext.accountObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.settingsObserve(op: String, args: JsonObject): Flow<JsonElement>? = null
internal fun NativeContext.supplementObserve(op: String): Flow<JsonElement>? = null
''')
(out / 'App.kt').write_text('''package io.github.nodyssey.ios
object NodysseyApp {
    lateinit var fixture: IosAppContainer
    suspend fun ensureContainer() = fixture
    fun nativeSiteMetadata(): kotlinx.serialization.json.JsonObject = error("unused public bootstrap")
}
''')
sources += [session.parent / 'PostRepository.kt', session.parent / 'FeedRemoteMediator.kt', session.parent / 'PostRemoteDataSource.kt', root / 'shared/src/commonMain/kotlin/io/github/nodyssey/core/html/PostDetailParser.kt']
sources += [native / f for f in ['NativeBridge.kt', 'NativeCountRefreshOwner.kt', 'NativeContent.kt', 'NativeContentMapping.kt', 'NativeAccountMapping.kt']]
sources += [out / 'UnusedDomains.kt', out / 'App.kt', root / 'iosapp/tests/fixtures/ThreadPreviewJvmTest.kt', root / 'iosapp/tests/fixtures/OwnedWorkspaceGraphTest.kt', junit_runner(out)]
# Freeze all sources before compilation. Include dispatcher/parser source manifests even where
# cached repository jars provide classes; record that distinction explicitly.
frozen = []
hashes = {}
for i, path in enumerate(sources):
    target = out / 'inputs' / f'{i:03}' / path.name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(path.read_bytes())
    hashes[str(path)] = hashlib.sha256(target.read_bytes()).hexdigest()
    frozen.append(target)
fixture = root / 'shared/src/commonTest/resources/fixtures/post-703863-1.html'
fixture_copy = out / fixture.name
fixture_copy.write_bytes(fixture.read_bytes())
manifest = {
    'source_sha256': {**hashes, str(graph): hashlib.sha256(graph.read_bytes()).hexdigest(), str(Path(__file__)): hashlib.sha256(Path(__file__).read_bytes()).hexdigest()},
    'fixture_sha256': {str(fixture): hashlib.sha256(fixture_copy.read_bytes()).hexdigest()},
    'dependency_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in jars},
    'complete_graph_class_body_sha256': hashlib.sha256(body.encode()).hexdigest(),
    'scaffold_sha256': hashlib.sha256(scaffold.encode()).hexdigest(),
    'jvm_real_room': True, 'apple_execution': False,
    'platform_seams': ['Foundation paths/NSURLSession', 'Coil', 'global services constructor', 'recorded HTML transport', 'unused account/settings/supplement dispatcher domains'],
}
(out / 'manifest.json').write_text(json.dumps(manifest, indent=2))
command = [java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-jvm-target', '21', '-opt-in=kotlin.uuid.ExperimentalUuidApi', '-Xfriend-paths=' + str(out / 'shared-jvm.jar'), *compiler_options(cache), '-classpath', cp, '-d', str(out / 'tests.jar'), *map(str, frozen)]
result = run(command, out, 'compile', 150)
if result.returncode:
    sys.exit(result.returncode)
result = run([java, '-Djava.io.tmpdir=' + str(out), '-Dpreview.fixture=' + str(fixture_copy), '-cp', str(out / 'tests.jar') + ':' + cp, 'io.github.nodyssey.ios.native.SettingsHarnessRunnerKt', 'io.github.nodyssey.ios.native.ThreadPreviewJvmTest', 'io.github.nodyssey.ios.OwnedWorkspaceGraphTest'], out, 'test', 90)
proofs = [json.loads(line.removeprefix('SIDE_EFFECT_PROOF ')) for line in (out / 'test.log').read_text().splitlines() if line.startswith('SIDE_EFFECT_PROOF ')]
(out / 'side-effect-proofs.json').write_text(json.dumps(proofs, indent=2))
print('MANIFEST', out / 'manifest.json')
sys.exit(result.returncode)
