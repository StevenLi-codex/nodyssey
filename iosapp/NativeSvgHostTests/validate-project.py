#!/usr/bin/env python3
"""macOS project graph checks only; neither iOS compilation nor XCTest execution."""
from pathlib import Path
import runpy
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
# Also retain the independent navigation suite's existing graph/one-testable scheme checks.
original = runpy.run_path(str(root / "iosapp/NativeNavigationUITests/validate-project.py"))
objects, main, app_id = (original[key] for key in ("objects", "main", "app_id"))
test_id, test = original["targets"]["NativeSvgHostTests"]
assert test["productType"] == "com.apple.product-type.bundle.unit-test"
assert main["attributes"]["TargetAttributes"][test_id]["TestTargetID"] == app_id
assert objects[test["productReference"]]["path"] == "NativeSvgHostTests.xctest"
assert test["productReference"] in objects[main["productRefGroup"]]["children"]
assert len(test["dependencies"]) == 1
assert objects[test["dependencies"][0]]["target"] == app_id
phases = [objects[key] for key in test["buildPhases"]]
sources = next(p for p in phases if p["isa"] == "PBXSourcesBuildPhase")
source_ids = [objects[key]["fileRef"] for key in sources["files"]]
assert [objects[key]["path"] for key in source_ids] == ["NativeSvgHostTests.swift"]
group_id, group = next((key, obj) for key, obj in objects.items()
                      if obj["isa"] == "PBXGroup" and obj.get("path") == "NativeSvgHostTests")
assert group_id in objects[main["mainGroup"]]["children"]
assert group["children"] == source_ids
assert (root / "iosapp/NativeSvgHostTests/NativeSvgHostTests.swift").is_file()
configs = [objects[key] for key in objects[test["buildConfigurationList"]]["buildConfigurations"]]
assert {config["name"] for config in configs} == {"Debug", "Release"}
for config in configs:
    settings = config["buildSettings"]
    assert settings["BUNDLE_LOADER"] == "$(TEST_HOST)"
    assert settings["TEST_HOST"] == "$(BUILT_PRODUCTS_DIR)/Nodyssey.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Nodyssey"
    assert "TEST_TARGET_NAME" not in settings
    assert settings["FRAMEWORK_SEARCH_PATHS"] == "$(SRCROOT)/build/xcode-frameworks/$(CONFIGURATION)/$(SDK_NAME)"
    assert settings["PRODUCT_BUNDLE_IDENTIFIER"] == "io.github.nodyssey.NativeSvgHostTests"
    assert settings["GENERATE_INFOPLIST_FILE"] == "YES"
    assert settings["CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"] == "NO"
    assert not settings.get("OTHER_LDFLAGS"), "Resolve Kotlin symbols from the app's bundle loader"
assert not test.get("fileSystemSynchronizedGroups")
assert not test.get("packageProductDependencies")
scheme = ET.parse(root / "iosapp/Nodyssey.xcodeproj/xcshareddata/xcschemes/NativeSvgHostTests.xcscheme")
for reference in scheme.iter("BuildableReference"):
    target = objects[reference.attrib["BlueprintIdentifier"]]
    assert target["name"] == reference.attrib["BlueprintName"]
    assert objects[target["productReference"]]["path"] == reference.attrib["BuildableName"]
testables = scheme.findall("./TestAction/Testables/TestableReference")
assert len(testables) == 1
assert testables[0].attrib == {"skipped": "NO", "parallelizable": "NO"}
reference = testables[0].find("BuildableReference")
assert reference is not None and reference.attrib["BlueprintIdentifier"] == test_id
action = scheme.find("TestAction")
assert action is not None and action.attrib["buildConfiguration"] == "Debug"
entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
entry_ids = set()
for entry in entries:
    reference = entry.find("BuildableReference")
    assert reference is not None
    entry_ids.add(reference.attrib["BlueprintIdentifier"])
assert entry_ids == {app_id, test_id}
assert all(e.attrib["buildForTesting"] == "YES" for e in entries)
print("STRUCTURE ONLY: separate SVG hosted unit-test target, real app loader, sources and scheme verified.")
print("NOT VERIFIED: new Kotlin export, iOS compile/link, XCTest discovery, app-hosted pixels.")
