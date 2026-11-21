#!/usr/bin/env python3
"""Compile exact opt-in shared boundary sources; run real file-backed JVM tests.
Not Apple compilation or platform callback evidence. No live HTTP.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import sys
root = Path(__file__).resolve().parents[2]
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
out = Path(tempfile.mkdtemp(prefix='private-boundary-', dir=os.environ['TMPDIR']))
java = str(Path.home() / '.cache/nodyssey-build/jdk21/bin/java')
coords = [('org.jetbrains.kotlin','kotlin-compiler-embeddable','2.4.20'),('org.jetbrains.kotlin','kotlin-stdlib','2.4.20'),('org.jetbrains.kotlin','kotlin-test','2.4.20'),('org.jetbrains.kotlin','kotlin-test-junit','2.4.20'),('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.11.0'),('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.11.0'),('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.11.0'),('org.jetbrains','annotations','23.0.0'),('junit','junit','4.13.2'),('org.hamcrest','hamcrest-core','1.3')]
jars = [p for g,a,v in coords for p in (cache/g/a/v).rglob('*.jar')]
jars += list((cache / 'org.jetbrains.kotlinx/kotlinx-datetime-jvm/0.8.0').rglob('*.jar'))
for group in ['androidx.datastore', 'androidx.paging', 'com.squareup.okio', 'androidx.collection', 'androidx.room', 'androidx.sqlite']:
    jars += list((cache/group).rglob('*.jar'))
jars += [root/f'{m}/build/libs/{m}-jvm.jar' for m in ['shared','richtext']]
cp = ':'.join(map(str,jars))
common = root/'shared/src/commonMain/kotlin'
sources = list((common/'io/github/nodyssey/data/session').glob('Private*.kt')) + list((common/'io/github/nodyssey/data/session').glob('SessionWork*.kt'))
sources += [common/p for p in ['io/github/plaza/core/net/SessionCookies.kt','io/github/nodyssey/data/session/SessionRepository.kt','io/github/nodyssey/data/composer/PostComposerRepository.kt','io/github/nodyssey/data/composer/CommentComposerRepository.kt']]
sources += [common / 'io/github/nodyssey/data' / name for name in ['PostRepository.kt', 'FeedRemoteMediator.kt']]
sources += list((root/'shared/src/jvmTest/kotlin/io/github/nodyssey/data/session').glob('PrivateBoundary*Test.kt'))
plugin = next((cache/'org.jetbrains.kotlin/kotlin-serialization-compiler-plugin-embeddable/2.4.20').rglob('*.jar'))
print('Artifacts:',out,flush=True)
commands = [[java,'-cp',cp,'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','21',f'-Xfriend-paths={root}/shared/build/libs/shared-jvm.jar','-opt-in=kotlin.uuid.ExperimentalUuidApi',f'-Xplugin={plugin}','-classpath',cp,'-d',str(out/'tests.jar')]+list(map(str,sources)),[java,f'-Djava.io.tmpdir={out}','-cp',str(out/'tests.jar')+':'+cp,'org.junit.runner.JUnitCore','io.github.nodyssey.data.session.PrivateBoundaryPersistenceTest']]
for i, cmd in enumerate(commands):
    try:
        result = subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120 if i==0 else 30)
    except subprocess.TimeoutExpired as e:
        print('TIMEOUT',e,flush=True)
        sys.exit(124)
    (out/f'{i}.log').write_text(result.stdout)
    print(result.stdout,flush=True)
    if result.returncode: sys.exit(result.returncode)
