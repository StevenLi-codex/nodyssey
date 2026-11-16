#!/usr/bin/env python3
"""Real Foundation/SwiftUI compiler checks on approved CLT Mac; not iOS linkage."""
import io
import hashlib
import uuid
import pathlib
import shlex
import subprocess
import sys
import os
import tarfile

repo = pathlib.Path(__file__).resolve().parents[2]
stage = os.environ.get("SETTINGS_MAC_STAGE", "/Users/steven/.cache/hermes-build/nodyssey-settings-" + uuid.uuid4().hex)
print("SETTINGS_MAC_STAGE", stage)
manifest = []
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for relative in ["iosapp/NativeSettingsUITests", "iosapp/Nodyssey/Native/Settings", "iosapp/NativeCore/Sources"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if any(s in item.name for s in ["/.build", "__pycache__", "/Evidence/"]) else item)
    if snapshots := os.environ.get("SETTINGS_PRESET_SNAPSHOTS"):
        tar.add(snapshots, arcname="preset-snapshots.json")
    for member in tar.getmembers():
        if member.isfile():
            source = pathlib.Path(os.environ["SETTINGS_PRESET_SNAPSHOTS"]) if member.name == "preset-snapshots.json" else repo / member.name
            manifest.append(hashlib.sha256(source.read_bytes()).hexdigest() + "  " + member.name)
    data = ("\n".join(manifest) + "\n").encode()
    info = tarfile.TarInfo("sources.sha256")
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
base = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && shasum -a 256 -c sources.sha256 && export TMPDIR={stage}/scratch && swift --version && "
if "--typecheck-ui" in sys.argv:
    command = base + "swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13.0 -emit-library -emit-module -module-name NodysseyNativeCore -o scratch/libNodysseyNativeCore.dylib -emit-module-path scratch/NodysseyNativeCore.swiftmodule iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift && swiftc -typecheck -swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13.0 -I scratch -module-cache-path scratch/module-cache iosapp/Nodyssey/Native/Settings/*.swift iosapp/NativeSettingsUITests/Typecheck/*.swift"
else:
    # Use the same base + production-action suites as CI, including SDK selection.
    command = base + "sh iosapp/NativeSettingsUITests/run-tests.sh"
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue(), capture_output=True)
output = result.stdout.decode() + result.stderr.decode()
print(output)
if "--log" in sys.argv:
    name = sys.argv[sys.argv.index("--log") + 1]
    log = pathlib.Path(__file__).parent / "Evidence" / name
    log.parent.mkdir(exist_ok=True)
    log.write_text(output + f"\nEXIT STATUS: {result.returncode}\n")
raise SystemExit(result.returncode)
