#!/usr/bin/env python3
"""macOS-only project graph audit. NOT an Xcode build or an XCTest run."""
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
project_path = root / "iosapp/Nodyssey.xcodeproj/project.pbxproj"
scheme_path = project_path.parent / "xcshareddata/xcschemes/Nodyssey.xcscheme"
subprocess.run(["plutil", "-lint", str(project_path)], check=True)
project = json.loads(subprocess.check_output(
    ["plutil", "-convert", "json", "-o", "-", str(project_path)], text=True
))
objects = project["objects"]
main = objects[project["rootObject"]]
targets = {objects[key]["name"]: (key, objects[key]) for key in main["targets"]}
app_id, app = targets["Nodyssey"]
test_id, test = targets["NativeNavigationUITests"]
assert app["productType"] == "com.apple.product-type.application"
assert test["productType"] == "com.apple.product-type.bundle.ui-testing"
assert main["attributes"]["TargetAttributes"][test_id]["TestTargetID"] == app_id
product = objects[test["productReference"]]
assert product["path"] == "NativeNavigationUITests.xctest"
assert test["productReference"] in objects[main["productRefGroup"]]["children"]

# Resolve graph edges, not a text-search approximation of a target.
scalar_edges = {
    "buildConfigurationList", "productReference", "fileRef", "productRef",
    "target", "targetProxy", "containerPortal", "mainGroup", "productRefGroup",
    "remoteGlobalIDString", "package",
}
list_edges = {
    "children", "buildPhases", "dependencies", "targets", "buildConfigurations",
    "files", "fileSystemSynchronizedGroups", "packageProductDependencies", "packageReferences",
}
for key, obj in objects.items():
    for field in scalar_edges & obj.keys():
        assert obj[field] in objects, (key, field, obj[field])
    for field in list_edges & obj.keys():
        for reference in obj[field]:
            assert reference in objects, (key, field, reference)

dependencies = [objects[key] for key in test["dependencies"]]
assert len(dependencies) == 1 and dependencies[0]["target"] == app_id
proxy = objects[dependencies[0]["targetProxy"]]
assert proxy["remoteGlobalIDString"] == app_id
assert proxy["containerPortal"] == project["rootObject"]
assert str(proxy["proxyType"]) == "1"

phases = [objects[key] for key in test["buildPhases"]]
assert {phase["isa"] for phase in phases} == {
    "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXResourcesBuildPhase"
}
sources = next(phase for phase in phases if phase["isa"] == "PBXSourcesBuildPhase")
source_ids = [objects[key]["fileRef"] for key in sources["files"]]
assert [objects[key]["path"] for key in source_ids] == ["NativeNavigationUITests.swift"]
test_group_id, test_group = next(
    (key, value) for key, value in objects.items()
    if value["isa"] == "PBXGroup" and value.get("path") == "NativeNavigationUITests"
)
assert test_group_id in objects[main["mainGroup"]]["children"]
assert source_ids == test_group["children"]
assert (root / "iosapp" / test_group["path"] / objects[source_ids[0]]["path"]).is_file()

config_ids = objects[test["buildConfigurationList"]]["buildConfigurations"]
assert {objects[key]["name"] for key in config_ids} == {"Debug", "Release"}
for key in config_ids:
    settings = objects[key]["buildSettings"]
    assert settings["TEST_TARGET_NAME"] == "Nodyssey"
    assert str(settings["IPHONEOS_DEPLOYMENT_TARGET"]) == "16.0"
    assert settings["GENERATE_INFOPLIST_FILE"] == "YES"
    assert settings["CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"] == "NO"
    assert settings["CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]"] == "NO"
    assert "TEST_HOST" not in settings, "UI tests use a runner, not a unit-test host"
    assert "NodysseyShell" not in settings.get("OTHER_LDFLAGS", [])

native = [objects[key] for key in app["fileSystemSynchronizedGroups"]]
assert any(item["isa"] == "PBXFileSystemSynchronizedRootGroup" and item["path"] == "Native"
           for item in native)
assert not test.get("fileSystemSynchronizedGroups")
assert any(objects[key].get("relativePath") == "NativeCore" for key in main["packageReferences"])
assert any(objects[key]["productName"] == "NodysseyNativeCore"
           for key in app["packageProductDependencies"])
app_phases = [objects[key] for key in app["buildPhases"]]
assert any(phase.get("name") == "Build Kotlin framework"
           and ":iosapp:embedAndSignAppleFrameworkForXcode" in phase["shellScript"]
           for phase in app_phases)
assert not test.get("packageProductDependencies")

scheme = ET.parse(scheme_path).getroot()
for reference in scheme.iter("BuildableReference"):
    target = objects[reference.attrib["BlueprintIdentifier"]]
    assert target["name"] == reference.attrib["BlueprintName"]
    assert objects[target["productReference"]]["path"] == reference.attrib["BuildableName"]
    assert reference.attrib["ReferencedContainer"] == "container:Nodyssey.xcodeproj"
testables = scheme.findall("./TestAction/Testables/TestableReference")
assert len(testables) == 1
assert testables[0].attrib["skipped"] == "NO"
assert testables[0].attrib["parallelizable"] == "NO"
testable_reference = testables[0].find("BuildableReference")
assert testable_reference is not None
assert testable_reference.attrib["BlueprintIdentifier"] == test_id
entries = scheme.findall("./BuildAction/BuildActionEntries/BuildActionEntry")
test_entries = [entry for entry in entries
                if any(reference.attrib["BlueprintIdentifier"] == test_id
                       for reference in entry.findall("BuildableReference"))]
assert len(test_entries) == 1
test_entry = test_entries[0]
assert test_entry.attrib["buildForTesting"] == "YES"
assert test_entry.attrib["buildForArchiving"] == "NO"
assert test_entry.attrib["buildForRunning"] == "NO"
print("STRUCTURE ONLY: app/test products, source membership, dependency, configurations,")
print("Native synchronized group, NativeCore, Kotlin host phase and shared scheme verified.")
print("NOT VERIFIED: Xcode project loading/build, iOS linking or XCTest runtime.")
