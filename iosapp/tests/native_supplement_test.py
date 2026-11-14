#!/usr/bin/env python3
"""Exact Kotlin supplement/settings sources against real JVM repository jars.
Apple Foundation shim is compile-only and always throws; never executed in tests.
Not an Apple build, Objective-C ABI check, or BGTaskScheduler runtime test.
"""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch'))) / 'native-supplement-jvm'
out.mkdir(parents=True, exist_ok=True)
jars = []
for group, artifact, version in [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-reflect', '2.2.21'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm', '1.11.0'),
    ('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test-junit', '2.4.20'),
    ('org.jetbrains', 'annotations', '23.0.0'),
    ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3')
]:
    jars += list((cache / group / artifact / version).rglob('*.jar'))
for group in ['androidx.datastore', 'com.squareup.okio', 'androidx.collection',
              'androidx.compose.runtime', 'org.jetbrains.compose.runtime']:
    jars += list((cache / group).rglob('*.jar'))
jars += [root / f'{module}/build/libs/{module}-jvm.jar' for module in ['shared', 'richtext', 'ui', 'designsys']]
cp = ':'.join(map(str, jars))
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
tests = root / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native'
adapter = out / 'CompileContext.kt'
adapter.write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.di.AppContainer
import io.github.nodyssey.data.dns.DohSupport
abstract class SettingsCompileGraph : AppContainer { abstract override val doh: DohSupport }
internal class NativeContext(val graph: SettingsCompileGraph)
internal class NativeFailure(val code: String) : Exception()
''')
foundation = out / 'CompileFoundation.kt'
foundation.write_text('''package platform.Foundation
class NSUserDefaults {
    fun stringForKey(key: String): String? = error("compile-only Apple API")
    fun setObject(value: Any?, forKey: String): Unit = error("compile-only Apple API")
    companion object { val standardUserDefaults: NSUserDefaults get() = error("compile-only Apple API") }
}
''')
app = out / 'CompileApp.kt'
app.write_text('''package io.github.nodyssey.ios
object NodysseyApp { suspend fun nativeForeground(): Unit = error("compile-only iOS graph") }
''')
platform = out / 'CompileAppleTransport.kt'
platform.write_text('''package io.github.plaza.core.net
fun deviceAcceptLanguage(): String = error("compile-only Apple API")
class CompileSession { fun finishTasksAndInvalidate(): Unit = error("compile-only Apple API") }
enum class ProxyRouteType { HTTP, SOCKS }
data class ProxyRoute(val type: ProxyRouteType, val host: String, val port: Int, val username: String = "", val password: String = "")
fun appleUrlSession(userAgent: String, acceptLanguage: String, referer: String? = null,
    timeoutSeconds: Double = 20.0, cookies: Any? = null, proxy: ProxyRoute? = null): CompileSession = error("compile-only Apple API")
class NSUrlSessionTransport(session: () -> CompileSession) : HttpTransport {
    override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse = error("compile-only Apple transport")
}
''')
sources = [str(adapter), str(foundation), str(app), str(platform)]
sources += [str(main / name) for name in ['NativeSettings.kt', 'NativeSettingsMapping.kt', 'NativeSupplement.kt', 'NativeReleaseNotes.kt']]
# Never let stale classes make an omitted source appear to compile.
import shutil
shutil.rmtree(out / 'classes', ignore_errors=True)
sources += [str(tests / name) for name in ['NativeSettingsPersistenceTest.kt', 'NativeSettingsMappingTest.kt', 'NativeSupplementTest.kt']]
result = subprocess.run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(out / 'classes')] + sources)
if result.returncode:
    sys.exit(result.returncode)
sys.exit(subprocess.run([java, f'-Djava.io.tmpdir={out}', '-cp', str(out / 'classes') + ':' + cp,
    'org.junit.runner.JUnitCore', 'io.github.nodyssey.ios.native.NativeSettingsMappingTest',
    'io.github.nodyssey.ios.native.NativeSettingsPersistenceTest', 'io.github.nodyssey.ios.native.NativeSupplementTest']).returncode)
