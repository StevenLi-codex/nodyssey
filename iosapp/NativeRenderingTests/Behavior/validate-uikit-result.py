#!/usr/bin/env python3
"""Fail-closed collector for the registered iOS UIKit rich-selection cases."""
import json
import pathlib
import sys

# Keep this explicit: adding a case requires updating this registration and count.
BEHAVIOR_KEYS = frozenset({
    "canonical-mixed-no-token-fragmentation",
    "mixed-native-partial-copy",
    "attachments-use-contained-shipping-image-hosts",
    "same-render-preserves-selection-and-hosts",
    "links-quotes-use-owner-unsafe-rejected",
    "canonical-rich-traits-retained",
    "selection-blocks-custom-back",
    "paragraph-hit-boundary",
    "signature-dynamic-type-semantic-font",
    "container-revoke-clears-hidden-copy-and-actions",
    "inactive-tab-never-projects-canonical-data",
    "reveal-restores-new-range-owner",
    "revoked-image-hosts-not-reparented",
    "mounted-tab-reselect-preserves-paragraph",
    "natural-textkit-provider-mounted",
    "mixed-copy-spans-attachments",
    "retained-image-rejected-after-revoke",
    "retained-image-rejected-after-reactivate",
    "retained-primary-uiaction-rejected-after-revoke",
    "retained-primary-uiaction-rejected-after-reactivate",
    "current-image-and-primary-uiaction-positive",
    "dismantle-clears-copy-hosts-and-actions",
})
TOP_LEVEL_KEYS = frozenset({"imageOwnerPass", "selectionPass"})
EXPECTED_CASE_COUNT = 24


def validate(path: pathlib.Path) -> dict:
    if not path.is_file():
        raise ValueError(f"result file not found: {path}")
    try:
        result = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(result, dict):
        raise ValueError("result must be a JSON object")
    behavior = result.get("behavior")
    if not isinstance(behavior, dict):
        raise ValueError("missing behavior object")
    missing = sorted(BEHAVIOR_KEYS - behavior.keys())
    extra = sorted(behavior.keys() - BEHAVIOR_KEYS)
    if missing or extra:
        raise ValueError(f"behavior key mismatch; missing={missing}, extra={extra}")
    missing_top = sorted(TOP_LEVEL_KEYS - result.keys())
    if missing_top:
        raise ValueError(f"missing top-level keys: {missing_top}")
    fields = {**{f"behavior.{k}": behavior[k] for k in sorted(BEHAVIOR_KEYS)},
              **{k: result[k] for k in sorted(TOP_LEVEL_KEYS)}}
    invalid = sorted(k for k, value in fields.items() if type(value) is not bool)
    if invalid:
        raise ValueError(f"non-boolean case values: {invalid}")
    failed = sorted(k for k, value in fields.items() if not value)
    if len(fields) != EXPECTED_CASE_COUNT:
        raise ValueError(f"registered case count {len(fields)} != {EXPECTED_CASE_COUNT}")
    if failed:
        raise ValueError(f"failed cases: {failed}")
    return {"outcome": "PASS", "case_count": len(fields), "cases": sorted(fields)}


if __name__ == "__main__":
    try:
        print(json.dumps(validate(pathlib.Path(sys.argv[1])), sort_keys=True))
    except (IndexError, ValueError) as exc:
        print(f"FAIL-CLOSED: {exc}", file=sys.stderr)
        sys.exit(1)
