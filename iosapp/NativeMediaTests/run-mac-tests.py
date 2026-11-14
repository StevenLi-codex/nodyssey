#!/usr/bin/env python3
"""Stage owned media sources and actual NativeCore on the existing CLT runner."""
import io
import pathlib
import shlex
import subprocess
import sys
import tarfile

repo = pathlib.Path(__file__).resolve().parents[2]
stage = "/Users/steven/.cache/hermes-build/nodyssey-media"
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for relative in ["iosapp/NativeMediaTests", "iosapp/Nodyssey/Native/Media", "iosapp/NativeCore"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if any(x in item.name for x in ["/.build", "__pycache__", "/Verification"]) else item)
command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swift --version && TMPDIR={stage}/scratch sh iosapp/NativeMediaTests/run-tests.sh"
if "--typecheck-ui" in sys.argv:
    command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -emit-module -target arm64-apple-macos14.0 -module-name NodysseyNativeCore -swift-version 6 -emit-module-path {stage}/scratch/NodysseyNativeCore.swiftmodule iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift && swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -typecheck -swift-version 6 -target arm64-apple-macos14.0 -I {stage}/scratch -module-cache-path {stage}/scratch/module-cache iosapp/Nodyssey/Native/Media/*.swift iosapp/NativeMediaTests/Typecheck/Contracts.swift"
raise SystemExit(subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue()).returncode)
