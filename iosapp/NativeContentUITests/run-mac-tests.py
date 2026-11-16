#!/usr/bin/env python3
"""Stage only renderer sources/tests on the approved Mac, then run SwiftPM."""
import io
import hashlib
import uuid
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tarfile

repo = pathlib.Path(__file__).resolve().parents[2]
stage = os.environ.get("CONTENT_MAC_STAGE", "/Users/steven/.cache/hermes-build/nodyssey-content-" + uuid.uuid4().hex)
manifest = []
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
archive = io.BytesIO()
replay = os.environ.get("CONTENT_REPOSITORY_REPLAY")
with tarfile.open(fileobj=archive, mode="w") as tar:
    if replay:
        tar.add(replay, arcname="scratch/reaction-repository-replay.json")
    for relative in ["iosapp/NativeContentUITests", "iosapp/Nodyssey/Native/Content", "iosapp/Nodyssey/Native/Sharing", "iosapp/Nodyssey/Native/Rendering", "iosapp/Nodyssey/Native/Editing", "iosapp/Nodyssey/Native/Account/AccountAuthorQuickCard.swift", "iosapp/Nodyssey/Native/Account/AccountAuthorQuickCardState.swift", "iosapp/Nodyssey/Native/Account/AccountProfileDate.swift", "iosapp/NativeCore/Sources"]:
        path = repo / relative
        if path.exists():
            tar.add(path, arcname=relative, filter=lambda item: None if "/.build" in item.name or "__pycache__" in item.name else item)
    for member in tar.getmembers():
        if member.isfile():
            source = pathlib.Path(replay) if replay and member.name == "scratch/reaction-repository-replay.json" else repo / member.name
            manifest.append(hashlib.sha256(source.read_bytes()).hexdigest() + "  " + member.name)
    data = ("\n".join(manifest) + "\n").encode()
    info = tarfile.TarInfo("sources.sha256")
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
replay_env = f"CONTENT_REPOSITORY_REPLAY={shlex.quote(stage + '/scratch/reaction-repository-replay.json')} " if replay else ""
if replay and 'relevantReceipt' in json.loads(pathlib.Path(replay).read_text()):
    replay_env += 'CONTENT_REPOSITORY_COMPLETE=1 '
if "--composition" in sys.argv:
    replay_env += "CONTENT_COMPOSITION=1 "
command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && shasum -a 256 -c sources.sha256 && swift --version && {replay_env}TMPDIR={stage}/scratch sh iosapp/NativeContentUITests/run-tests.sh"
if "--typecheck-ui" in sys.argv:
    flags = f"-swift-version 6 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos13.0 -module-cache-path {stage}/scratch/module-cache"
    command = f"mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && shasum -a 256 -c sources.sha256 && swiftc {flags} -emit-module -module-name NodysseyNativeCore iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path {stage}/scratch/NodysseyNativeCore.swiftmodule && swiftc {flags} -I {stage}/scratch -typecheck iosapp/Nodyssey/Native/Rendering/*.swift iosapp/Nodyssey/Native/Content/*.swift iosapp/Nodyssey/Native/Sharing/*.swift iosapp/Nodyssey/Native/Editing/EditorState.swift iosapp/Nodyssey/Native/Editing/EditorViewModel.swift iosapp/Nodyssey/Native/Editing/NativeEditorScreens.swift iosapp/Nodyssey/Native/Editing/NativePostComposerPresentation.swift iosapp/Nodyssey/Native/Editing/EditorPanels.swift iosapp/Nodyssey/Native/Editing/EditorMessageThread.swift iosapp/Nodyssey/Native/Editing/EditorRichPreview.swift iosapp/Nodyssey/Native/Editing/EditorThreadReply.swift iosapp/Nodyssey/Native/Account/AccountAuthorQuickCard.swift iosapp/Nodyssey/Native/Account/AccountAuthorQuickCardState.swift iosapp/Nodyssey/Native/Account/AccountProfileDate.swift iosapp/NativeContentUITests/Typecheck/Contracts.swift iosapp/NativeContentUITests/Typecheck/ThreadEditorContracts.swift"
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue())
raise SystemExit(result.returncode)
