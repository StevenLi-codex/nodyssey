"""Executes the shipping guest policy on JVM; also checks its bridge wiring."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = root / 'iosapp/src/iosMain/kotlin/io/github/nodyssey/ios/native/PreviewGuestPolicy.kt'
assert source.exists(), 'Missing production guest gate: account operations currently reach repositories'
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
def jar(group, name, version):
    exact = list((cache / group / name / version).glob('*/*.jar'))
    # The compiler's coroutine runtime can differ from the application's pinned runtime
    # on a Native-only runner; the policy itself uses no coroutine API.
    if not exact and name == 'kotlinx-coroutines-core-jvm':
        exact = list((cache / group / name).glob('*/*/*.jar'))
    if not exact:
        raise RuntimeError(f'Missing compiler dependency: {group}:{name}:{version}')
    return str(sorted(exact)[0])
cp = ':'.join([jar('org.jetbrains.kotlin', 'kotlin-stdlib', '2.4.20'), jar('org.jetbrains', 'annotations', '23.0.0'), jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.11.0')])
compiler = jar('org.jetbrains.kotlin', 'kotlin-compiler-embeddable', '2.4.20')
tests = '''package io.github.nodyssey.ios.native
fun main() {
    val blocked = listOf("session.signIn", "session.sync", "session.verifyTwoFactor", "session.signOut", "assets.transfer", "editor.image.upload", "account.changePassword", "messages.send", "thread.react", "vote.submit", "imageHost.save", "cache.clear", "offline.clear", "future.operation", "draft.post.get", "profile.self")
    blocked.forEach { check(!PreviewGuestPolicy.allows(it, false, null)) { it } }
    listOf("site.get", "categories.get", "thread.load", "thread.position.set").forEach { check(PreviewGuestPolicy.allows(it, false, null)) { it } }
    listOf("feed", "thread", "settings.observe", "session.state").forEach { check(PreviewGuestPolicy.allows(it, true, null)) { it } }
    check(!PreviewGuestPolicy.allows("thread.load", true, null))
    check(PreviewGuestPolicy.allows("settings.set", false, "themeMode"))
    check(PreviewGuestPolicy.allows("settings.set", false, "onboardingSeen"))
    check(!PreviewGuestPolicy.allows("settings.set", false, "cookie"))
    check(!PreviewGuestPolicy.allows("settings.set", false, null))
    check(!PreviewGuestPolicy.browserAllowed("challenge"))
    check(!PreviewGuestPolicy.browserAllowed("login"))
    check(!PreviewGuestPolicy.sessionAllowed(true))
    check(PreviewGuestPolicy.sessionAllowed(false))
    println("PASS: preview default-deny request/observe, local settings, browser and signed-session gates")
}
'''
with tempfile.TemporaryDirectory(prefix='preview-policy-', dir=os.environ.get('TMPDIR')) as folder:
    folder = Path(folder)
    test = folder / 'PreviewTests.kt'
    test.write_text(tests)
    out = folder / 'tests.jar'
    subprocess.run(['java', '-cp', compiler + ':' + cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', cp, '-d', str(out), str(source), str(test)], check=True)
    subprocess.run(['java', '-cp', str(out) + ':' + cp, 'io.github.nodyssey.ios.native.PreviewTestsKt'], check=True)
bridge = (source.parent / 'NativeBridge.kt').read_text()
assert bridge.count('previewRequireOperation(operation, argumentsJson,') == 2
assert 'PreviewGuestPolicy.sessionAllowed(session.isSignedIn)' in bridge
platform = (source.parent / 'NativePlatform.kt').read_text()
assert 'PreviewGuestPolicy.browserAllowed("external")' in platform, 'External image browser can still reach authenticated Safari pages'
start = platform.split('fun start(completion:', 1)[1]
assert start.index('PreviewGuestPolicy.browserAllowed(goal)') < start.index('lifecycle.open()')
print('PASS: production request/observe and browser gate wiring')
