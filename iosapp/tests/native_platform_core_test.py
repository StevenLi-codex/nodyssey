"""Run the platform-free production region on Linux; NOT an Apple SDK build.

JAVA must name a Java 21 executable. Uses the repository's cached, pinned Kotlin
compiler/coroutine artifacts. The tests themselves also run in iosTest on a Mac.
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(group, name, version):
    return str(next((cache / group / name / version).glob('*/*.jar')))
cp = ':'.join([
    jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'),
    jar('org.jetbrains.kotlin', 'kotlin-test', '2.4.20'),
    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0'),
    jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-test-jvm', '1.11.0'),
    jar('org.jetbrains', 'annotations', '23.0.0'),
])
compiler = jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20')
java = os.environ.get('JAVA', 'java')
production = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native/NativePlatform.kt'
assert production.exists(), 'Native platform behavior is not implemented'
region = production.read_text().split('// PLATFORM_FREE_BEGIN\n', 1)[1]
tests = (root / 'iosapp/src/iosTest/kotlin/io/github/nodyssey/ios/native/NativePlatformTest.kt').read_text()
names = re.findall(r'fun `([^`]+)`', tests)
tests = tests.replace('import kotlin.test.Test\n', '').replace('    @Test\n', '')
tests += '\nfun main() { val tests = NativePlatformTest();\n' + '\n'.join(f'tests.`{n}`(); println("PASS: {n}")' for n in names) + '\n}\n'
state = (root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session/SessionRepository.kt').read_text().split('data class SessionState(', 1)[1]
with tempfile.TemporaryDirectory(prefix='native-platform-', dir=os.environ['TMPDIR']) as d:
    d = Path(d)
    (d / 'Policy.kt').write_text('package io.github.nodyssey.ios.native\nimport io.github.nodyssey.data.session.SessionState\nimport io.github.plaza.core.net.WebUrl\nimport kotlinx.coroutines.sync.Mutex\nimport kotlinx.coroutines.sync.withLock\n' + region)
    (d / 'Tests.kt').write_text(tests)
    (d / 'State.kt').write_text('package io.github.nodyssey.data.session\ndata class SessionState(' + state)
    sources = [str(x) for x in d.glob('*.kt')] + [str(root / 'shared/src/commonMain/kotlin/io/github/plaza/core/net/WebUrl.kt')]
    subprocess.run([java, '-cp', compiler + ':' + cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(d / 'test.jar')] + sources, check=True)
    subprocess.run([java, '-cp', str(d / 'test.jar') + ':' + cp, 'io.github.nodyssey.ios.native.TestsKt'], check=True)
