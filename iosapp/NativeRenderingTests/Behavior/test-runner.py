#!/usr/bin/env python3
"""Collector/runner regression checks, not synthetic UIKit acceptance."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("collector", HERE / "validate-uikit-result.py")
assert spec and spec.loader
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorBoundaryTests(unittest.TestCase):
    def test_actual_runner_rejects_incomplete_or_failed_evidence(self):
        runner = HERE / "run-uikit-behavior.py"
        self.assertTrue(runner.is_file(), "No reproducible iOS UIKit behavior runner")
        complete = {"behavior": dict.fromkeys(collector.BEHAVIOR_KEYS, True),
                    **dict.fromkeys(collector.TOP_LEVEL_KEYS, True)}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            baseline_keys = collector.BEHAVIOR_KEYS - {
                "mounted-tab-reselect-preserves-paragraph", "natural-textkit-provider-mounted",
                "mixed-copy-spans-attachments", "retained-image-rejected-after-revoke",
                "retained-image-rejected-after-reactivate", "retained-primary-uiaction-rejected-after-revoke",
                "retained-primary-uiaction-rejected-after-reactivate", "current-image-and-primary-uiaction-positive",
                "dismantle-clears-copy-hosts-and-actions"}
            self.assertEqual(len(baseline_keys), 13)
            variants = {"missing-file": None, "invalid-json": "{", "non-object": "[]",
                "missing-behavior": json.dumps({"selectionPass": True, "imageOwnerPass": True}),
                "old-13-plus-2": json.dumps({"behavior": dict.fromkeys(baseline_keys, True),
                    "selectionPass": True, "imageOwnerPass": True})}
            for key in collector.TOP_LEVEL_KEYS:
                value = json.loads(json.dumps(complete))
                del value[key]
                variants["missing-top-" + key] = json.dumps(value)
            for key in collector.BEHAVIOR_KEYS:
                value = json.loads(json.dumps(complete))
                del value["behavior"][key]
                variants["missing-" + key] = json.dumps(value)
                value = json.loads(json.dumps(complete))
                value["behavior"][key] = False
                variants["false-" + key] = json.dumps(value)
            for key in collector.TOP_LEVEL_KEYS:
                for invalid in (False, 1, None, "true"):
                    value = json.loads(json.dumps(complete))
                    value[key] = invalid
                    variants[f"invalid-{key}-{invalid}"] = json.dumps(value)
            for name, text in variants.items():
                with self.subTest(name=name):
                    path = root / (name + ".json")
                    if text is not None:
                        path.write_text(text)
                    result = subprocess.run([sys.executable, str(runner), "--collect", str(path)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
            path = root / "collector-unit-positive.json"
            path.write_text(json.dumps(complete))
            result = subprocess.run([sys.executable, str(runner), "--collect", str(path)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["case_count"], collector.EXPECTED_CASE_COUNT)


if __name__ == "__main__":
    unittest.main()
