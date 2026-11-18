#!/usr/bin/env python3
"""Execute refresh behavior tests and typecheck the actual iPhoneOS UIKit branch."""
import hashlib
import io
import json
import os
import pathlib
import shlex
import subprocess
import tarfile
import uuid

repo = pathlib.Path(__file__).resolve().parents[2]
run_id = "native-refresh-" + uuid.uuid4().hex[:12]
stage = "/Users/steven/.cache/hermes-build/" + run_id
artifacts = pathlib.Path(os.environ.get("TMPDIR", str(pathlib.Path.home() / ".cache"))) / run_id
artifacts.mkdir(parents=True, exist_ok=True)
outer = ["ssh", "-p", "18323", "-i", "/home/hermes/.ssh/n100_london_ed25519", "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/home/hermes/.ssh/known_hosts_n100_service", "steven@127.0.0.1"]
inner = ["ssh", "-o", "Hostname=StevendeMacBook-Pro.local", "-o", "HostKeyAlias=192.168.31.128", "-o", "StrictHostKeyChecking=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "macbook"]
files = ["iosapp/NativeRefreshTests/NativeRefreshTests.swift", "iosapp/Nodyssey/Native/Foundation/NativeRefreshState.swift", "iosapp/Nodyssey/Native/Foundation/NativeRefreshable.swift"]
archive = io.BytesIO()
hashes = {}
with tarfile.open(fileobj=archive, mode="w") as tar:
    for item in files:
        data = (repo / item).read_bytes()
        hashes[item] = hashlib.sha256(data).hexdigest()
        info = tarfile.TarInfo(item)
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
# Keep the algorithm test tied to the exact shipping implementation.
view_source = (repo / files[2]).read_text()
resolution = view_source[view_source.index("    private func resolve() {"):view_source.index("    private func attach(_ owner:")]
fixture_path = "iosapp/NativeRefreshTests/ScrollResolutionTests.swift"
fixture = (repo / fixture_path).read_text().replace("    // SHIPPING_RESOLUTION_METHODS", resolution)
archive.seek(0)
with tarfile.open(fileobj=archive, mode="a") as tar:
    data = fixture.encode()
    info = tarfile.TarInfo("ScrollResolutionTests.swift")
    info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
manifest = {"stage": stage, "sha256": hashes, "topology_fixture_sha256": hashlib.sha256(fixture.encode()).hexdigest(), "ios_target": "arm64-apple-ios16.0", "developer_dir": "/Volumes/Development/Applications/Xcode.app/Contents/Developer"}
(artifacts / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
state, view = files[1:]
command = f"set -eu; mkdir -p {stage}/scratch; tar xf - -C {stage}; cd {stage}; "
command += "export TMPDIR=" + shlex.quote(stage + "/scratch") + "; "
command += "export DEVELOPER_DIR=" + shlex.quote(manifest["developer_dir"]) + "; "
command += "xcrun swift --version; xcrun --sdk iphoneos --show-sdk-path; xcrun --sdk iphoneos --show-sdk-version; "
command += "shasum -a 256 " + shlex.join(files) + "; "
command += f"xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library {state} {files[0]} -o scratch/tests; scratch/tests; "
command += "xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library ScrollResolutionTests.swift -o scratch/topology-tests; scratch/topology-tests; "
command += f"xcrun swiftc -swift-version 6 -warnings-as-errors -sdk $(xcrun --sdk iphoneos --show-sdk-path) -target arm64-apple-ios16.0 -typecheck {state} {view}; printf 'PASS actual iPhoneOS UIKit + SwiftUI typecheck\\n'; "
command += f"xcrun swiftc -swift-version 6 -warnings-as-errors -sdk $(xcrun --sdk macosx --show-sdk-path) -target arm64-apple-macos13.0 -typecheck {state} {view}; printf 'PASS actual macOS SwiftUI typecheck\\n'"
manifest["command"] = command
result = subprocess.run(outer + [shlex.join(inner + [command])], input=archive.getvalue(), stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
output = result.stdout.decode(errors="replace")
(artifacts / "validation.log").write_text(output)
manifest["exit_code"] = result.returncode
manifest["sources_unchanged"] = all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
manifest["pass_lines"] = [line for line in output.splitlines() if line.startswith("PASS ")]
(artifacts / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(output, end="")
print("Artifacts:", artifacts)
raise SystemExit(result.returncode if manifest["sources_unchanged"] else 1)
