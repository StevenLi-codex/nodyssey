#!/usr/bin/env python3
"""Isolated approved Mac staging; never touches the app project or a live account."""
import io
import os
import pathlib
import shlex
import subprocess
import sys
import tarfile

repo = pathlib.Path(__file__).resolve().parents[2]
stage = os.environ.get("SHARING_MAC_STAGE", "/Users/steven/.cache/hermes-build/nodyssey-sharing")
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for relative in ["iosapp/NativeSharingTests", "iosapp/Nodyssey/Native/Sharing", "iosapp/NativeCore/Sources", "iosapp/Nodyssey/Native/Content", "iosapp/Nodyssey/Native/Rendering", "iosapp/Nodyssey/Native/Foundation/NativePageCanvas.swift", "iosapp/Nodyssey/Native/Foundation/NativeGlassSurface.swift", "iosapp/NativeContentUITests/Typecheck/Contracts.swift"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if "/.build" in item.name or "__pycache__" in item.name else item)
qstage = shlex.quote(stage)
render_env = f"SHARING_RENDER_OUTPUT={qstage}/scratch/renders " if "--render-artifacts" in sys.argv else ""
command = f"mkdir -p {qstage}/scratch && tar xf - -C {qstage} && cd {qstage} && swift --version && {render_env}TMPDIR={qstage}/scratch sh iosapp/NativeSharingTests/run-tests.sh"
if "--typecheck-entry" in sys.argv or "--typecheck-content" in sys.argv:
    flags = f"-swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13.0 -module-cache-path {qstage}/scratch/module-cache"
    sources = "iosapp/Nodyssey/Native/Foundation/NativePageCanvas.swift iosapp/Nodyssey/Native/Foundation/NativeGlassSurface.swift iosapp/Nodyssey/Native/Rendering/*.swift iosapp/Nodyssey/Native/Content/*.swift" if "--typecheck-content" in sys.argv else "iosapp/Nodyssey/Native/Rendering/RichDocument.swift iosapp/Nodyssey/Native/Content/ContentShareLink.swift"
    command = f"mkdir -p {qstage}/scratch && tar xf - -C {qstage} && cd {qstage} && swiftc {flags} -emit-module -module-name NodysseyNativeCore iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path {qstage}/scratch/NodysseyNativeCore.swiftmodule && swiftc {flags} -I {qstage}/scratch -typecheck {sources} iosapp/Nodyssey/Native/Sharing/*.swift iosapp/NativeContentUITests/Typecheck/Contracts.swift"
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue())
if result.returncode == 0 and "--render-artifacts" in sys.argv:
    output = pathlib.Path(os.environ.get("SHARING_LOCAL_RENDER_OUTPUT", os.environ.get("TMPDIR", ".") + "/nodyssey-sharing-renders"))
    packed = subprocess.run(outer + [shlex.join(inner + [f"tar cf - -C {qstage}/scratch/renders ."])], capture_output=True, check=True)
    output.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(packed.stdout)) as tar:
        for member in tar.getmembers():
            if member.isfile() and pathlib.PurePosixPath(member.name).name == member.name.removeprefix("./") and member.name.endswith(".png"):
                source = tar.extractfile(member)
                if source is not None:
                    (output / pathlib.PurePosixPath(member.name).name).write_bytes(source.read())
    print(f"Rendered fixture PNGs: {output}")
raise SystemExit(result.returncode)
