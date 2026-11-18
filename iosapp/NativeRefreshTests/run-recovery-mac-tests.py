#!/usr/bin/env python3
"""Run the real Store/Feed refresh recovery composition on a remote Mac."""
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tarfile
import uuid

repo = Path(__file__).resolve().parents[2]
run_id = "refresh-recovery-" + uuid.uuid4().hex[:12]
stage = os.environ.get("REFRESH_MAC_STAGE", "/Volumes/Development/hermes-build/" + run_id)
artifacts = Path(os.environ.get("TMPDIR", str(Path.home() / ".cache"))) / run_id
artifacts.mkdir(parents=True, exist_ok=True)
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
files = {}
for folder in ["iosapp/NativeCore", "iosapp/NativeFoundationTests", "iosapp/Nodyssey/Native/Foundation", "iosapp/Nodyssey/Native/Editing", "iosapp/Nodyssey/Native/Rendering"]:
    for path in (repo / folder).rglob("*"):
        if path.is_file() and not any(part in path.parts for part in [".build", "__pycache__", "Verification"]):
            files[str(path.relative_to(repo))] = path.read_bytes()
for name in ["AccountAuthState", "AccountAuthSubmission"]:
    path = "iosapp/Nodyssey/Native/Account/" + name + ".swift"
    files[path] = (repo / path).read_bytes()
path = "iosapp/NativeEditorTests/TestSupport/Focus.swift"
files[path] = (repo / path).read_bytes()
source = (repo / "iosapp/Nodyssey/Native/Content/ContentState.swift").read_text()
# Execute shipping policy/type definitions, not permissive Feed stand-ins.
policy = "import Foundation\nimport NodysseyNativeCore\n"
policy += source[source.index("struct ContentFeedTicket:"):source.index("struct ContentFeedVisibleRow:")]
policy += source[source.index("struct ContentPagingWindow:"):]
files["iosapp/NativeFoundationTests/Sources/FeedPolicy.swift"] = policy.encode()
for target, source in [
    ("Sources/ContentFeedTopRefresh.swift", "iosapp/Nodyssey/Native/Content/ContentFeedTopRefresh.swift"),
    ("Tests/RecoveryStoreTests.swift", "iosapp/NativeRefreshTests/RecoveryStoreTests.swift"),
]:
    files["iosapp/NativeFoundationTests/" + target] = (repo / source).read_bytes()
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as tar:
    for name, data in files.items():
        item = tarfile.TarInfo(name)
        item.size = len(data)
        tar.addfile(item, io.BytesIO(data))
command = f"set -e; mkdir -p {shlex.quote(stage)}/scratch; tar xf - -C {shlex.quote(stage)}; cd {shlex.quote(stage)}; "
command += f"export TMPDIR={shlex.quote(stage)}/scratch; export CLANG_MODULE_CACHE_PATH={shlex.quote(stage)}/scratch/module-cache; export SWIFT_MODULECACHE_PATH={shlex.quote(stage)}/scratch/module-cache; "
command += "export DEVELOPER_DIR=/Volumes/Development/Applications/Xcode.app/Contents/Developer; sh iosapp/NativeFoundationTests/run-tests.sh"
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
output = result.stdout.decode(errors="replace")
(artifacts / "validation.log").write_text(output)
(artifacts / "manifest.json").write_text(json.dumps({"stage": stage, "exit_code": result.returncode, "sha256": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}, indent=2))
print(output)
print("Artifacts:", artifacts)
raise SystemExit(result.returncode)
