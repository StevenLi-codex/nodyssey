#!/usr/bin/env python3
"""Run actual editor state sources, never live repository mutations."""
import io
import pathlib
import shlex
import subprocess
import tarfile
import uuid
repo = pathlib.Path(__file__).resolve().parents[2]
# Concurrent gates must not replace one another's sources or module caches.
stage = f'/Users/steven/.cache/hermes-build/nodyssey-editor-{uuid.uuid4().hex}'
print(f'Mac stage: {stage}', flush=True)
outer = ['ssh', '-p', '18323', '-i', '/home/hermes/.ssh/n100_london_ed25519', '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service', 'steven@127.0.0.1']
inner = ['ssh', '-o', 'Hostname=StevendeMacBook-Pro.local', '-o', 'HostKeyAlias=192.168.31.128', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'macbook']
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w') as tar:
    for relative in ['iosapp/NativeEditorTests', 'iosapp/Nodyssey/Native/Editing', 'iosapp/NativeCore', 'iosapp/Nodyssey/Native/Rendering', 'iosapp/Nodyssey/Native/Foundation/NativeDestination.swift', 'iosapp/Nodyssey/Native/Foundation/NativeStore.swift']:
        p = repo / relative
        if p.exists():
            tar.add(p, arcname=relative, filter=lambda x: None if '/.build' in x.name or '__pycache__' in x.name else x)
command = f'mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swift --version && TMPDIR={stage}/scratch sh iosapp/NativeEditorTests/run-tests.sh'
import sys
if '--typecheck-ui' in sys.argv:
    command = f'mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swift --version && TMPDIR={stage}/scratch sh iosapp/NativeEditorTests/typecheck-ui.sh'
import time
result = None
for attempt in range(3):
    result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue())
    if result.returncode != 255:
        break
    time.sleep(2)
assert result is not None
raise SystemExit(result.returncode)
