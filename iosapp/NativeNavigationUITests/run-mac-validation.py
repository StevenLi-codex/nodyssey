#!/usr/bin/env python3
"""Stage only the project and UI tests on the existing approved Mac SSH route.

Structural validation and Swift parsing only: never called a simulator test run.
Uses SSH configuration literals from the existing rendering runner without
executing that runner. No credentials are copied or printed.
"""
import ast
import io
from pathlib import Path
import shlex
import subprocess
import tarfile

root = Path(__file__).resolve().parents[2]
existing_runner = root / "iosapp/NativeRenderingTests/run-mac-tests.py"
config = {}
for node in ast.parse(existing_runner.read_text()).body:
    if (isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id in {"outer", "inner"}):
        config[node.targets[0].id] = ast.literal_eval(node.value)
assert config.keys() == {"outer", "inner"}, "Existing approved Mac SSH config changed"

stage = "/Users/steven/.cache/hermes-build/nodyssey-native-navigation-audit"
files = [
    "iosapp/Nodyssey.xcodeproj/project.pbxproj",
    "iosapp/Nodyssey.xcodeproj/xcshareddata/xcschemes/Nodyssey.xcscheme",
    "iosapp/NativeNavigationUITests/NativeNavigationUITests.swift",
    "iosapp/NativeNavigationUITests/validate-project.py",
]
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode="w") as bundle:
    for relative in files:
        bundle.add(root / relative, arcname=relative, recursive=False)
command = (
    f"set -e; mkdir -p {shlex.quote(stage)}/scratch; "
    f"tar xf - -C {shlex.quote(stage)}; cd {shlex.quote(stage)}; "
    f"export TMPDIR={shlex.quote(stage)}/scratch; "
    "python3 iosapp/NativeNavigationUITests/validate-project.py; "
    "swiftc -frontend -parse -swift-version 5 "
    "iosapp/NativeNavigationUITests/NativeNavigationUITests.swift; "
    "printf '%s\\n' 'SWIFT PARSE ONLY: syntax accepted; XCTest APIs not typechecked'; "
    "xcode-select -p; "
    "if xcodebuild -version; then "
    "printf '%s\\n' 'Full Xcode detected; run the documented CI gate on the full checkout'; "
    "else printf '%s\\n' 'RUNTIME BLOCKED: full Xcode/simulator required'; fi"
)
result = subprocess.run(config["outer"] + [shlex.join(config["inner"] + [command])],
                        input=archive.getvalue())
raise SystemExit(result.returncode)
