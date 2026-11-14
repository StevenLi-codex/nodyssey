#!/usr/bin/env python3
"""Execute the exact native settings dispatch/lock with test-only image repositories.

Uses real pinned JVM domain jars, a signature-only native graph refinement and
throwing Apple transport signatures. NOT an Apple compile or a live host test.
Executes the concrete iosTest suite unchanged through the production repository-only
locked seam. The compile graph is never instantiated; no JVM-only test subclass,
reflection repository graph, test-owned mutex, or rewritten production source.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch'))) / 'native-image-host-selection-jvm'
out.mkdir(parents=True, exist_ok=True)
jars = []
for group, artifact, version in [
    ('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-script-runtime', '2.4.20'),
    ('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-core-jvm', '1.11.0'),
    ('org.jetbrains.kotlinx', 'kotlinx-serialization-json-jvm', '1.11.0'),
    ('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
    ('org.jetbrains.kotlin', 'kotlin-test-junit', '2.4.20'),
    ('org.jetbrains', 'annotations', '23.0.0'),
    ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3'),
]:
    found = list((cache / group / artifact / version).rglob('*.jar'))
    if not found:
        raise SystemExit(f'Missing pinned dependency: {group}:{artifact}:{version}')
    jars += found
for group in ['androidx.datastore', 'com.squareup.okio', 'androidx.collection',
              'androidx.compose.runtime', 'org.jetbrains.compose.runtime']:
    jars += list((cache / group).rglob('*.jar'))
for module in ['shared', 'richtext', 'ui', 'designsys']:
    jar = root / f'{module}/build/libs/{module}-jvm.jar'
    if not jar.exists():
        raise SystemExit(f'Missing real repository jar: {jar}')
    jars.append(jar)
cp = ':'.join(map(str, jars))
java = os.environ.get('JAVA', str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java'))
main = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native'
tests = root / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native'
adapter = out / 'CompileContext.kt'
adapter.write_text('''package io.github.nodyssey.ios.native
import io.github.nodyssey.di.AppContainer
import io.github.nodyssey.data.dns.DohSupport
interface SettingsCompileGraph : AppContainer { override val doh: DohSupport }
internal class NativeContext(val graph: SettingsCompileGraph)
internal class NativeFailure(val code: String) : Exception()
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
runner = out / 'ImageHostSelectionRunner.kt'
runner.write_text('''package io.github.nodyssey.ios.native
import org.junit.runner.JUnitCore
import org.junit.runner.Description
import org.junit.runner.notification.RunListener

fun main() {
    val runner = JUnitCore()
    runner.addListener(object : RunListener() {
        override fun testStarted(description: Description) {
            println("RUN ${description.className}.${description.methodName}")
        }
    })
    val result = runner.run(NativeImageHostSelectionTest::class.java)
    result.failures.forEach { println(it.trace) }
    println("Tests run: ${result.runCount}; failures: ${result.failureCount}; ignored: ${result.ignoreCount}")
    check(result.wasSuccessful() && result.runCount == 8 && result.ignoreCount == 0)
}
''')
sources = [adapter, platform, runner, tests / 'NativeImageHostSelectionTest.kt']
sources += [main / name for name in ['NativeSettings.kt', 'NativeSettingsMapping.kt', 'NativeReleaseNotes.kt']]
classes = out / 'classes'
shutil.rmtree(classes, ignore_errors=True)
result = subprocess.run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                         '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(classes)] + list(map(str, sources)))
if result.returncode:
    sys.exit(result.returncode)
sys.exit(subprocess.run([java, f'-Djava.io.tmpdir={out}', '-cp', str(classes) + ':' + cp,
                        'io.github.nodyssey.ios.native.ImageHostSelectionRunnerKt']).returncode)
