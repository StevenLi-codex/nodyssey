#!/usr/bin/env python3
"""Run exact release-notes Kotlin on pinned JVM dependencies, not an Apple build.
Foundation/transport signatures throw if executed. --live additionally retrieves and
parses the original public URL with real JVM HTTP (never a fake Apple success).
"""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch'))) / 'native-release-notes-jvm'
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
    ('junit', 'junit', '4.13.2'), ('org.hamcrest', 'hamcrest-core', '1.3')
]:
    found = list((cache / group / artifact / version).rglob('*.jar'))
    if not found:
        raise SystemExit(f'Missing pinned dependency: {group}:{artifact}:{version}')
    jars += found
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
sources = [str(adapter), str(platform)]
sources += [str(main / name) for name in ['NativeSettings.kt', 'NativeSettingsMapping.kt', 'NativeReleaseNotes.kt'] if (main / name).exists()]
sources += [str(p) for p in tests.glob('NativeReleaseNotes*.kt') if not p.name.endswith('AppleTest.kt')]
sources += [str(tests / name) for name in ['NativeSettingsMappingTest.kt', 'NativeSettingsPersistenceTest.kt']]
if '--live' in sys.argv:
    live = out / 'LiveReleaseNotes.kt'
    live.write_text('''package io.github.nodyssey.ios.native
import io.github.plaza.core.net.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import java.net.URI
import java.net.HttpURLConnection
import java.security.MessageDigest
fun main() = runBlocking {
    var bytes = ByteArray(0)
    var status = 0
    val http = object : HttpTransport {
        override suspend fun execute(request: HttpRequest, onUploadProgress: UploadProgress?): HttpResponse {
            check(request.url == RELEASE_NOTES_URL && request.method == "GET" && request.body == null)
            val connection = URI(request.url).toURL().openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 20000
            connection.readTimeout = 20000
            request.headers.forEach { (key, value) -> connection.setRequestProperty(key, value) }
            try {
                status = connection.responseCode
                bytes = (if (status in 200..299) connection.inputStream else connection.errorStream)
                    ?.use { it.readNBytes(1048577) } ?: ByteArray(0)
                check(bytes.size <= 1048576)
                return HttpResponse(status, connection.url.toString(), emptyMap(), bytes.toString(Charsets.UTF_8))
            } finally { connection.disconnect() }
        }
    }
    val result = fetchReleaseNotes(http, true)
    val releases = result.getValue("releases").jsonArray
    val published = Json.parseToJsonElement(bytes.toString(Charsets.UTF_8)).jsonObject.getValue("versions").jsonArray
    check(releases.size == published.size && releases.isNotEmpty())
    check(releases.all { it.jsonObject.getValue("text").jsonPrimitive.content.isNotBlank() })
    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    println("Live JVM HTTP $status; bytes=${bytes.size}; sourceRows=${published.size}; parsedRows=${releases.size}; sha256=$sha")
    println("Newest=${releases.first().jsonObject.getValue("versionName")}; original source=$RELEASE_NOTES_URL")
}
''')
    sources.append(str(live))
classes = out / 'classes'
# Fresh output prevents stale bootstrap/classes influencing later runs.
import shutil
shutil.rmtree(classes, ignore_errors=True)
result = subprocess.run([java, '-cp', cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(classes)] + sources)
if result.returncode:
    sys.exit(result.returncode)
suites = ['io.github.nodyssey.ios.native.' + Path(p).stem for p in sources if p.endswith('Test.kt')]
result = subprocess.run([java, f'-Djava.io.tmpdir={out}', '-cp', str(classes) + ':' + cp, 'org.junit.runner.JUnitCore'] + suites)
if result.returncode or '--live' not in sys.argv:
    sys.exit(result.returncode)
sys.exit(subprocess.run([java, '-cp', str(classes) + ':' + cp, 'io.github.nodyssey.ios.native.LiveReleaseNotesKt']).returncode)
