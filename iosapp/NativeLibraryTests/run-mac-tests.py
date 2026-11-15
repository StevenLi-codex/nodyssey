#!/usr/bin/env python3
"""Stage only renderer sources/tests on the approved Mac, then run SwiftPM."""
import io
import pathlib
import shlex
import subprocess
import sys
import tarfile
import uuid

repo = pathlib.Path(__file__).resolve().parents[2]
stage = "/Users/steven/.cache/hermes-build/nodyssey-library-" + uuid.uuid4().hex
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for relative in ["iosapp/NativeLibraryTests", "iosapp/Nodyssey/Native/Library", "iosapp/NativeCore/Sources"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if "/.build" in item.name or "__pycache__" in item.name else item)
command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && shasum -a 256 iosapp/Nodyssey/Native/Library/LibraryAssets.swift iosapp/Nodyssey/Native/Library/LibraryBehavior.swift iosapp/NativeLibraryTests/Tests/*swift && swift --version && TMPDIR={stage}/scratch sh iosapp/NativeLibraryTests/run-tests.sh"
if "--typecheck-ui" in sys.argv:
    command = command.replace("run-tests.sh", "typecheck-ui.sh")
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue())
raise SystemExit(result.returncode)
