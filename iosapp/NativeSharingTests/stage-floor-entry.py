#!/usr/bin/env python3
"""Compile the real floor action expression, not a second context implementation.

This wiring guard is deliberately separate from the runtime Swift tests: it proves
where the entry lives; Swift executes its exact initializer and document boundary.
It does not claim to tap a rendered SwiftUI row or present a system share sheet.
"""
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "iosapp/Nodyssey/Native/Content/ContentThread.swift").read_text()
start = source.index("@ViewBuilder private func floor(")
end = source.index("private func reactionButton(", start)
floor = source[start:end]
assert "ContentShareLink(" in floor, "The actual floor row has no image-capable share entry"
start = floor.index("ContentShareLink(")
end = start + len("ContentShareLink")
depth = 0
for index in range(end, len(floor)):
    if floor[index] == "(":
        depth += 1
    elif floor[index] == ")":
        depth -= 1
        if depth == 0:
            end = index + 1
            break
else:
    raise AssertionError("Unbalanced floor entry initializer")
entry = floor[start:end]
assert "shareContext:" in entry, "Floor action still has identifiers only"
assert 'floor(body, page: 1, opening: true)' in source
assert 'floor(comment, page: page, opening: false)' in source
assert 'let comment = row.value' in source and 'let page = row.page' in source
assert 'ContentShareLink(postID: postID, page: visibleTarget?.page ?? firstPage, floor: visibleTarget?.floor)' in source, "Keep toolbar URL sharing independent of any guessed row"
# The reveal identity is the same production expression used by the body gate.
identity = next(line.strip() for line in floor.splitlines() if line.strip().startswith("let identity ="))
assert 'if value.nativeBool("isBlocked") == true && !expanded.contains(identity)' in floor
result = '''import SwiftUI
import NodysseyNativeCore

// Generated only in the test stage from ContentPostDetail.floor's actual entry.
@MainActor func actualFloorEntry(value: JSONValue, page: Int64, opening: Bool,
                                postID: Int64, threadValue: JSONValue,
                                expanded: Set<String> = []) -> ContentShareLink {
    let thread = NativeStore()
    thread.value = threadValue
    ''' + identity + '''
    return ''' + entry + '''
}
'''
path = pathlib.Path(sys.argv[1])
path.write_text(result)
print("Staged exact ContentPostDetail.floor share entry (toolbar preserved)")
