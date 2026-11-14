#!/usr/bin/env python3
"""Stage project/host-test syntax checks over the existing approved Mac route. NOT acceptance."""
import ast
import io
from pathlib import Path
import shlex
import subprocess
import tarfile

root = Path(__file__).resolve().parents[2]
config = {}
for node in ast.parse((root / "iosapp/NativeRenderingTests/run-mac-tests.py").read_text()).body:
    if (isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in {"outer", "inner"}):
        config[node.targets[0].id] = ast.literal_eval(node.value)
assert config.keys() == {"outer", "inner"}
stage = "/Users/steven/.cache/hermes-build/nodyssey-svg-host-audit"
files = [
    "iosapp/Nodyssey.xcodeproj/project.pbxproj",
    "iosapp/Nodyssey.xcodeproj/xcshareddata/xcschemes/Nodyssey.xcscheme",
    "iosapp/Nodyssey.xcodeproj/xcshareddata/xcschemes/NativeSvgHostTests.xcscheme",
    "iosapp/NativeNavigationUITests/NativeNavigationUITests.swift",
    "iosapp/NativeNavigationUITests/validate-project.py",
    "iosapp/NativeSvgHostTests/NativeSvgHostTests.swift",
    "iosapp/NativeSvgHostTests/validate-project.py",
]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as bundle:
    for relative in files:
        bundle.add(root / relative, arcname=relative, recursive=False)
command = (
    f"set -e; mkdir -p {shlex.quote(stage)}/scratch; "
    f"tar xf - -C {shlex.quote(stage)}; cd {shlex.quote(stage)}; "
    f"export TMPDIR={shlex.quote(stage)}/scratch; "
    "python3 iosapp/NativeSvgHostTests/validate-project.py; "
    "swiftc -frontend -parse -swift-version 5 iosapp/NativeSvgHostTests/NativeSvgHostTests.swift; "
    "printf '%s\\n' 'SYNTAX ONLY: XCTest/UIKit/Kotlin APIs not typechecked'; "
    "xcode-select -p; "
    "if xcodebuild -version; then "
    "printf '%s\\n' 'Run documented CI gate against full checkout'; "
    "else printf '%s\\n' 'RUNTIME BLOCKED: full Xcode/simulator required'; fi"
)
result = subprocess.run(config["outer"] + [shlex.join(config["inner"] + [command])],
                        input=archive.getvalue())
raise SystemExit(result.returncode)
