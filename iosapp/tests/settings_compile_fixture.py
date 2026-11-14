"""Isolated JVM compile support; never substitutes for a private-session guard."""
from pathlib import Path
import hashlib
import json
import os
import signal
import shutil
import subprocess
import tempfile
import zipfile


def output_directory(prefix):
    scratch = Path(os.environ.get('TMPDIR', str(Path.home() / '.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix=prefix + '-', dir=scratch))
    print('Artifacts:', out, flush=True)
    return out


def repository_jars(root, out):
    """Do not let Kotlin mmap jars that another build can overwrite."""
    jars = []
    manifest = {}
    for module in ['shared', 'richtext', 'ui', 'designsys']:
        source = root / f'{module}/build/libs/{module}-jvm.jar'
        if not source.is_file():
            raise SystemExit(f'Missing real repository jar: {source}')
        snapshot = out / source.name
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        shutil.copyfile(source, snapshot)
        digest = hashlib.sha256(snapshot.read_bytes()).hexdigest()
        after = hashlib.sha256(source.read_bytes()).hexdigest()
        if not before == digest == after:
            raise SystemExit(f'Build jar changed during snapshot; retry after build: {source}')
        with zipfile.ZipFile(snapshot) as archive:
            if archive.testzip() is not None:
                raise SystemExit(f'Invalid build jar snapshot: {source}')
        manifest[str(source)] = {'snapshot': str(snapshot), 'sha256': digest}
        jars.append(snapshot)
    (out / 'repository-jars.json').write_text(json.dumps(manifest, indent=2))
    return jars


def boundary_sources(root, out):
    """Compile the actual guard and its journal/barrier, not a permissive shim."""
    common = root / 'shared/src/commonMain/kotlin/io/github/nodyssey/data/session'
    sources = [common / name for name in [
        'PrivateSessionBoundary.kt', 'SessionWorkBarrier.kt', 'PrivateStoreProvenance.kt',
    ]]
    (out / 'boundary-sources.json').write_text(json.dumps({
        str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources
    }, indent=2))
    return sources


def compiler_options(cache):
    plugins = list((cache / 'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
    if len(plugins) != 1:
        raise SystemExit('Expected one pinned Kotlin 2.4.20 serialization compiler plugin')
    return ['-opt-in=kotlin.uuid.ExperimentalUuidApi', f'-Xplugin={plugins[0]}']


def run(command, out, name, timeout):
    """Keep bounded, named logs and reap only this invocation's process group."""
    log = out / f'{name}.log'
    with log.open('w') as stream:
        child = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                 start_new_session=True)
        timed_out = False
        try:
            child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=3)
    print(log.read_text(), end='', flush=True)
    result = subprocess.CompletedProcess(command, 124 if timed_out else child.returncode)
    (out / f'{name}-result.json').write_text(json.dumps({
        'command': command, 'exit_code': result.returncode, 'timeout': timed_out,
        'log': str(log),
    }, indent=2))
    return result


def junit_runner(out):
    """Name every executed unchanged JUnit case without modifying its suite."""
    source = out / 'SettingsHarnessRunner.kt'
    source.write_text('''package io.github.nodyssey.ios.native
import org.junit.runner.JUnitCore
import org.junit.runner.Description
import org.junit.runner.notification.RunListener
fun main(args: Array<String>) {
    val runner = JUnitCore()
    runner.addListener(object : RunListener() {
        override fun testStarted(d: Description) { println("RUN ${d.className}.${d.methodName}") }
    })
    val result = runner.run(*args.map { Class.forName(it) }.toTypedArray())
    result.failures.forEach { println(it.trace) }
    println("Tests run: ${result.runCount}; failures: ${result.failureCount}; ignored: ${result.ignoreCount}")
    check(result.wasSuccessful() && result.runCount > 0 && result.ignoreCount == 0)
}
''')
    return source
