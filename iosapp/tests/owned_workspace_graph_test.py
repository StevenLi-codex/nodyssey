#!/usr/bin/env python3
"""Compile the ENTIRE production IosAppContainer and router, run real JVM Room/DataStore.
Apple path/network/Coil and global process services are platform fixtures, not Apple execution.
"""
from pathlib import Path
import os, sys, subprocess, re, json, hashlib
root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / 'iosapp/tests'))
# Reuse pinned classpath provisioning and isolated jar snapshots, not generated graph code.
source = (root / 'iosapp/tests/native_session_security_test.py').read_text()
sys.argv = [str(root / 'iosapp/tests/native_session_security_test.py'), '--graph-integration']
__file__ = sys.argv[0]
exec(source[:source.index('# Only graph construction')])
base = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios'
production = base / 'IosAppContainer.kt'
text = production.read_text()
# Remove unused imports only; retain the whole production class unchanged.
body = text[text.index('/** Immutable, owned'):]
imports = [line for line in text.splitlines() if line.startswith('import ') and re.search(r'\b'+re.escape(line.rsplit('.',1)[-1])+r'\b', body)]
(out / 'OwnedGraph.kt').write_text('package io.github.nodyssey.ios\n'+'\n'.join(imports)+'\n'+body)
(out / 'owned-source.json').write_text(json.dumps({'source':str(production),'sha256':hashlib.sha256(production.read_bytes()).hexdigest(),'class_body_sha256':hashlib.sha256(body.encode()).hexdigest()},indent=2))
sources = [out / 'OwnedGraph.kt', base / 'IosAppCacheStore.kt', root / 'iosapp/tests/fixtures/OwnedWorkspacePlatform.kt', root / 'iosapp/tests/fixtures/OwnedWorkspaceGraphTest.kt']
sources += list((root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session').glob('Private*.kt'))
sources += [root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/local/GlobalCatalogueImport.kt']
sources += [root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session/SessionWorkBarrier.kt', root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/settings/WorkspaceSettingsDataStore.kt', root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/local/WorkspaceTitleKeywordDao.kt']
# JVM factory equivalents use the same explicit paths and owned scopes.
(out / 'Factory.kt').write_text('''package io.github.nodyssey.data
import androidx.datastore.preferences.core.*
import kotlinx.coroutines.CoroutineScope
import okio.Path.Companion.toPath
fun createPreferenceDataStore(name: String, scope: CoroutineScope, directory: String) = PreferenceDataStoreFactory.createWithPath(scope = scope, produceFile = { "$directory/$name.preferences_pb".toPath() })
''')
(out / 'RoomFactory.kt').write_text('''package io.github.nodyssey.data.local
import androidx.room.Room
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
fun createNodeSeekDatabase(path: String = java.io.File(io.github.nodyssey.ios.fixtureRoot,"legacy.db").path) = Room.databaseBuilder<NodeSeekDatabase>(path).setDriver(BundledSQLiteDriver()).build()
''')
(out / 'Foundation.kt').write_text('''package platform.Foundation
class NSURL(val path: String?) { companion object { fun fileURLWithPath(path: String, isDirectory: Boolean) = NSURL(path) } }
class NSURLSession
''')
(out / 'Cinterop.kt').write_text('''package kotlinx.cinterop
@RequiresOptIn annotation class ExperimentalForeignApi
''')
(out / 'Coil.kt').write_text('''package coil3
import okio.Path.Companion.toPath
object PlatformContext { val INSTANCE = this }
class Cache(path: String = "unused") {
    val keys = mutableSetOf<String>(); val size get() = keys.size.toLong()
    val directory = path.toPath()
    fun clear() { keys.clear(); java.io.File(directory.toString()).listFiles().orEmpty().forEach { it.deleteRecursively() } }
    fun shutdown() {}
}
class ImageLoader(path: String = "unused") { val memoryCache: Cache? = Cache(); val diskCache: Cache? = Cache(path); fun shutdown() {} }
''')
(out / 'OfflineImage.kt').write_text('''package io.github.nodyssey.data.offline
import platform.Foundation.NSURLSession
class UrlSessionOfflineImageSource(session: () -> NSURLSession) { suspend fun fetch(url: String, maxBytes: Long): ByteArray? = error("No network") }
''')
(out / 'Evict.kt').write_text('package io.github.plaza.designsys.image\nfun coil3.ImageLoader.evictImage(url: String) = Unit\n')
sources += [out / 'Evict.kt']
sources += [out / f for f in ['Factory.kt','RoomFactory.kt','Foundation.kt','Cinterop.kt','Coil.kt','OfflineImage.kt']]
plugin = next((cache / 'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
result = run_bounded([java,'-cp',cp,'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',cp,'-d',str(out/'tests.jar'),'-Xplugin='+str(plugin),'-jvm-target','21','-Xfriend-paths='+str(out/'shared-jvm.jar')] + list(map(str,sources)), 'compile-owned-graph',90)
if result['returncode']: sys.exit(result['returncode'])
result = run_bounded([java,f'-Djava.io.tmpdir={out}','-cp',str(out/'tests.jar')+':'+cp,'org.junit.runner.JUnitCore','io.github.nodyssey.ios.OwnedWorkspaceGraphTest'],'owned-graph-tests',45)
sys.exit(result['returncode'])
