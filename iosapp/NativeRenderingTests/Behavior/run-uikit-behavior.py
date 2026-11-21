#!/usr/bin/env python3
"""Reproducible iOS-only gate. Prepare locally; execute on an authorized Mac.

No SSH, archive, CI or global Xcode settings. The caller owns remote serialization.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
PRODUCTION = ["Rendering/RichDocument.swift", "Rendering/NativeInlineArrangement.swift",
              "Rendering/NativeRenderingMemo.swift", "Rendering/NativeRichSelection.swift",
              "Rendering/NativeRichText.swift", "Foundation/NativePressStyle.swift"]


def collector():
    spec = importlib.util.spec_from_file_location("uikit_collector", HERE / "validate-uikit-result.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("Shipping seam drifted: " + old[:90])
    return source.replace(old, new, 1)


def stage(repo, destination):
    native = repo / "iosapp/Nodyssey/Native"
    destination.mkdir(parents=True, exist_ok=False)
    originals = destination / "originals"
    originals.mkdir()
    manifest = {"production": {}, "staged": {}, "seams": []}
    for relative in PRODUCTION:
        path = native / relative
        data = path.read_bytes()
        (originals / path.name).write_bytes(data)
        source = data.decode()
        manifest["production"][str(path.relative_to(repo))] = hashlib.sha256(data).hexdigest()
        if path.name == "NativeRichText.swift":
            block = """Button {
                            guard selected != index else { return }
                            selection.revoke()
                            selected = index
                        } label: {"""
            source = replace_once(source, block, block.replace("Button {", "let tabAction = {", 1).replace("} label: {", "}\n                        Button(action: tabAction) {", 1))
            trait = "                        .accessibilityAddTraits(selected == index ? [.isSelected] : [])"
            observer = """
                        .onReceive(NotificationCenter.default.publisher(for: MountedTabProbe.notification)) { note in
                            guard note.object as? Int == index else { return }
                            MountedTabProbe.invocations.append(index)
                            tabAction()
                        }"""
            source = replace_once(source, trait, trait + observer)
            manifest["seams"].append("Actual mounted Button and current-render notification share its unchanged tab action")
        if path.name == "NativeRichSelection.swift":
            guard = "        guard isActive, case let .link(url) = textItem.content else { return nil }\n"
            # UITextItem has no public initializer. Share its exact unchanged return block
            # with a URL-only fixture seam; no fabricated UITextItem or private API.
            source = replace_once(source, guard, guard + "        return behaviorPrimaryActionForLink(url)\n    }\n    @available(iOS 17.0, *)\n    func behaviorPrimaryActionForLink(_ url: URL) -> UIAction {\n")
            manifest["seams"].append("iOS17 delegate shares unchanged UIAction factory with URL-only fixture seam; no system UITextItem/touch claim")
        (destination / path.name).write_text(source)
    remote = native / "Platform/NativeRemoteImage.swift"
    data = remote.read_bytes()
    manifest["production"][str(remote.relative_to(repo))] = hashlib.sha256(data).hexdigest()
    text = data.decode()
    leaf = text[text.index("/// Uses the installed"):text.index("/// A gallery destination")]
    display = text[text.index("private struct NativeImageDisplay"):text.index("// Geometry/admission")]
    exact_leaf = "import SwiftUI\nimport UIKit\n" + leaf + display
    (originals / "ImageLeaf.swift").write_text(exact_leaf)
    leaf = replace_once(leaf, "Button(action: onOpen) { loadedImage(image) }", "Button(action: onOpen) { loadedImage(image) }\n                        .onReceive(NotificationCenter.default.publisher(for: .init(\"behavior.image\"))) { _ in onOpen() }")
    (destination / "ImageLeaf.swift").write_text("import SwiftUI\nimport UIKit\n" + leaf + display)
    manifest["seams"].append("Exact loaded image Button onOpen replay; shipping image-state replaced by preloaded raster boundary")
    for name in ["Boundaries.swift", "Main.swift", "MountedTabBehavior.swift", "NaturalParagraphBehavior.swift", "NativeRichSelectionBehavior.swift", "validate-uikit-result.py", "run-uikit-behavior.py"]:
        shutil.copyfile(HERE / name, destination / name)
    (destination / "SDKProbe.swift").write_text("import SwiftUI\nimport UIKit\n@MainActor enum Probe { static var localOpen = 0 }\n")
    for path in sorted(destination.rglob("*")):
        if path.is_file():
            manifest["staged"][str(path.relative_to(destination))] = hashlib.sha256(path.read_bytes()).hexdigest()
    (destination / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def execute(args):
    if sys.platform != "darwin":
        raise RuntimeError("UIKit behavior must execute on macOS with an iOS Simulator SDK, never a macOS target")
    inputs = args.inputs.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    commands = []
    report = {"outcome": "BLOCKED", "commands": commands, "source_manifest": json.loads((inputs / "source-manifest.json").read_text())}

    def run(argv, label, timeout=180):
        start = time.monotonic()
        completed = subprocess.run([str(x) for x in argv], cwd=inputs, capture_output=True, text=True, timeout=min(timeout, 900))
        log = output / (label + ".log")
        log.write_text(completed.stdout + completed.stderr)
        commands.append({"argv": [str(x) for x in argv], "exit_code": completed.returncode, "seconds": time.monotonic() - start, "log": str(log)})
        if completed.returncode:
            raise RuntimeError(label + " failed; see " + str(log))
        return completed.stdout.strip()

    try:
        for name, digest in report["source_manifest"]["staged"].items():
            if hashlib.sha256((inputs / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError("Frozen input changed: " + name)
        device_sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], "device-sdk")
        simulator_sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], "simulator-sdk")
        original_sources = sorted((inputs / "originals").glob("*.swift"))
        run(["xcrun", "swiftc", "-typecheck", "-swift-version", "5", "-sdk", device_sdk, "-target", "arm64-apple-ios16.0", *original_sources, inputs / "Boundaries.swift", inputs / "SDKProbe.swift"], "unmodified-production-sdk")
        app = output / "Behavior.app"
        app.mkdir()
        identifier = "invalid.nodyssey.formal-media-selection"
        (app / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier=identifier, CFBundleExecutable="Behavior", CFBundleName="Behavior", CFBundlePackageType="APPL", CFBundleVersion="1", CFBundleShortVersionString="1", LSRequiresIPhoneOS=True, UILaunchScreen={})))
        sources = [path for path in sorted(inputs.glob("*.swift")) if path.name != "SDKProbe.swift"]
        run(["xcrun", "swiftc", "-swift-version", "5", "-sdk", simulator_sdk, "-target", "arm64-apple-ios16.0-simulator", "-o", app / "Behavior", *sources], "compile-ios-simulator")
        run(["codesign", "--force", "--sign", "-", app], "codesign")
        device_set = args.device_set.resolve() if args.device_set else output / "sim-devices"
        device_set.mkdir(parents=True, exist_ok=True)
        simctl = ["xcrun", "simctl", "--set", str(device_set)]
        available = json.loads(run(simctl + ["list", "devices", "available", "-j"], "list-devices"))["devices"]
        device = args.device
        if not device:
            booted = [x["udid"] for values in available.values() for x in values if x["state"] == "Booted"]
            if booted:
                device = booted[0]
            else:
                runtimes = json.loads(run(simctl + ["list", "runtimes", "-j"], "list-runtimes"))["runtimes"]
                ios = [r for r in runtimes if r.get("isAvailable") and "iOS" in r["name"]]
                if not ios:
                    raise RuntimeError("No available iOS runtime")
                runtime = max(ios, key=lambda r: tuple(map(int, r["version"].split("."))))
                device = run(simctl + ["create", "FormalMediaSelection", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"]], "create-device")
        report["device"] = device
        report["device_set"] = str(device_set)
        matches = [x for values in available.values() for x in values if x["udid"] == device]
        if not matches or matches[0]["state"] != "Booted":
            run(simctl + ["boot", device], "boot")
        run(simctl + ["bootstatus", device, "-b"], "bootstatus", 240)
        run(simctl + ["install", device, app], "install-diagnostic")
        container = Path(run(simctl + ["get_app_container", device, identifier, "data"], "data-container"))
        result_file = container / "Documents/result.json"
        result_file.unlink(missing_ok=True)
        run(simctl + ["launch", "--terminate-running-process", device, identifier], "launch-diagnostic")
        deadline = time.monotonic() + 75
        while not result_file.is_file() and time.monotonic() < deadline:
            time.sleep(0.5)
        if not result_file.is_file():
            raise RuntimeError("No runtime result.json before bounded deadline")
        shutil.copyfile(result_file, output / "result.json")
        report["result"] = json.loads((output / "result.json").read_text())
        report["result_sha256"] = hashlib.sha256((output / "result.json").read_bytes()).hexdigest()
        # The actual process exit is the strict collector's outcome, not the last log line.
        run([sys.executable, inputs / "validate-uikit-result.py", output / "result.json"], "strict-collector", 20)
        report["outcome"] = "PASS"
    except Exception as error:
        report["blocker"] = str(error)
        if "result" in report:
            report["outcome"] = "FAIL"
    finally:
        (output / "run-report.json").write_text(json.dumps(report, indent=2) + "\n")
        print("FORMAL_UIKIT_REPORT " + json.dumps(report, sort_keys=True))
    return 0 if report["outcome"] == "PASS" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collect", type=Path)
    parser.add_argument("--prepare-request", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--inputs", type=Path, default=HERE)
    parser.add_argument("--output", type=Path, default=Path("uikit-behavior-output"))
    parser.add_argument("--repo", type=Path, default=HERE.parents[2])
    parser.add_argument("--device-set", type=Path)
    parser.add_argument("--device")
    args = parser.parse_args()
    if args.collect:
        print(json.dumps(collector().validate(args.collect), sort_keys=True))
        return 0
    if args.execute:
        return execute(args)
    if args.prepare_request:
        request = args.prepare_request.resolve()
        request.parent.mkdir(parents=True, exist_ok=True)
        frozen = request.with_suffix(".inputs")
        stage(args.repo.resolve(), frozen)
        command = ["python3", "run-uikit-behavior.py", "--execute", "--inputs", ".", "--output", "runtime-output"]
        if args.device_set:
            command += ["--device-set", str(args.device_set)]
        if args.device:
            command += ["--device", args.device]
        files = {str(path.relative_to(frozen)): str(path) for path in frozen.rglob("*") if path.is_file()}
        request.write_text(json.dumps({"files": files, "command": shlex.join(command), "timeout": 600}, indent=2) + "\n")
        print(request)
        return 0
    parser.error("Choose --prepare-request, --execute or --collect")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("FAIL-CLOSED: " + str(error), file=sys.stderr)
        sys.exit(1)
