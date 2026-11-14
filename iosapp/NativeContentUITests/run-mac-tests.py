#!/usr/bin/env python3
"""Stage only renderer sources/tests on the approved Mac, then run SwiftPM."""
import io
import pathlib
import shlex
import subprocess
import sys
import tarfile

repo = pathlib.Path(__file__).resolve().parents[2]
stage = "/Users/steven/.cache/hermes-build/nodyssey-content"
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for relative in ["iosapp/NativeContentUITests", "iosapp/Nodyssey/Native/Content", "iosapp/Nodyssey/Native/Rendering", "iosapp/NativeCore/Sources"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if "/.build" in item.name or "__pycache__" in item.name else item)
command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swift --version && TMPDIR={stage}/scratch sh iosapp/NativeContentUITests/run-tests.sh"
if "--typecheck-ui" in sys.argv:
    flags = f"-swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13.0 -module-cache-path {stage}/scratch/module-cache"
    command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swiftc {flags} -emit-module -module-name NodysseyNativeCore iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path {stage}/scratch/NodysseyNativeCore.swiftmodule && swiftc {flags} -I {stage}/scratch -typecheck iosapp/Nodyssey/Native/Rendering/*.swift iosapp/Nodyssey/Native/Content/*.swift iosapp/NativeContentUITests/Typecheck/Contracts.swift"
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue())
raise SystemExit(result.returncode)
