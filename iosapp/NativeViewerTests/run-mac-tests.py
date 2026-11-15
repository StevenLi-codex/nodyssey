#!/usr/bin/env python3
"""Real Foundation execution and exact UIKit-region signature check with explicit stand-ins."""
import hashlib
import io
import pathlib
import shlex
import subprocess
import tarfile
import uuid

repo = pathlib.Path(__file__).resolve().parents[2]
stage = '/Users/steven/.cache/hermes-build/nodyssey-viewer-' + uuid.uuid4().hex
outer = ['ssh', '-p', '18323', '-i', '/home/hermes/.ssh/n100_london_ed25519', '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service', 'steven@127.0.0.1']
inner = ['ssh', '-o', 'Hostname=StevendeMacBook-Pro.local', '-o', 'HostKeyAlias=192.168.31.128', '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', 'macbook']
source_path = repo / 'iosapp/Nodyssey/Native/Platform/NativeRemoteImage.swift'
source = source_path.read_text()
policy = source[source.index('enum NativeImageGesturePolicy {'):source.index('private struct NativeZoomImage:')] if 'enum NativeImageGesturePolicy {' in source else ''
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w') as tar:
    tar.add(repo / 'iosapp/NativeViewerTests', arcname='tests', filter=lambda item: None if '__pycache__' in item.name else item)
    tar.add(source_path, arcname='NativeRemoteImage.swift')
    for name, text in [('Policy.swift', 'import Foundation\nimport CoreGraphics\n' + policy), ('Zoom.swift', 'import SwiftUI\nimport UIKit\n' + source[source.index('private struct NativeZoomImage:'):])]:
        data = text.encode()
        entry = tarfile.TarInfo(name)
        entry.size = len(data)
        tar.addfile(entry, io.BytesIO(data))
flags = '-swift-version 5 -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -target arm64-apple-macos14.0 -module-cache-path scratch/cache'
command = f'mkdir -p {stage}/scratch && tar xf - -C {stage} && cd {stage} && shasum -a 256 NativeRemoteImage.swift && swift --version && swiftc {flags} Policy.swift tests/Tests/ViewerGestureTests.swift -o scratch/tests && scratch/tests'
if (repo / 'iosapp/NativeViewerTests/Typecheck/UIKit.swift').exists():
    command += f' && swiftc {flags} -emit-module -module-name UIKit tests/Typecheck/UIKit.swift -emit-module-path scratch/UIKit.swiftmodule && swiftc {flags} -I scratch -typecheck Policy.swift Zoom.swift tests/Typecheck/Representable.swift && printf "UIKit-region signature check PASS (stand-ins; not iOS execution)\\n"'
print('STAGE:', stage, flush=True)
print('SOURCE_SHA256:', hashlib.sha256(source_path.read_bytes()).hexdigest(), flush=True)
raise SystemExit(subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue()).returncode)
