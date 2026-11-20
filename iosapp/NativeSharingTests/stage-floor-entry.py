#!/usr/bin/env python3
"""Execute the shipping sheet's share initializer and reveal identity in Swift.

Wiring assertions guard extraction only; the Swift suite checks document behavior.
This does not claim SwiftUI row taps or system share-sheet presentation.
"""
import pathlib
import sys

repo = pathlib.Path(__file__).resolve().parents[2]
source = (repo / "iosapp/Nodyssey/Native/Content/ContentThread.swift").read_text()


def region(start, end):
    return source[source.index(start):source.index(end, source.index(start))]


sheet = region("@ViewBuilder private func floorActionSheet(", "private func reactionTile(")
start = sheet.index("ContentShareLink(")
depth = 0
for index in range(start + len("ContentShareLink"), len(sheet)):
    if sheet[index] == "(":
        depth += 1
    elif sheet[index] == ")":
        depth -= 1
        if depth == 0:
            entry = sheet[start:index + 1]
            break
else:
    raise AssertionError("Unbalanced floor entry initializer")
assert "shareContext:" in entry, "Floor action still has identifiers only"
assert "floorActions(body, page: 1, opening: true)" in source
assert "floorActions(row.value, page: row.page, opening: false)" in source
assert "let value = selection.opening ? thread.value[\"body\"] : row?.value" in sheet
assert "!blocked(value, opening: selection.opening)" in sheet
assert "selectedFloor = .init(id: identity(value, opening: opening), opening: opening)" in source
assert "expanded.insert(identity(value, opening: opening))" in source
assert "ContentShareLink(postID: postID, page: currentPage, floor: visibleTarget?.floor)" in source
helpers = region("private func identity(", "private var openingCard:").replace("private func", "func")
title = region("private var title: String {", "private var covered:")
title_expression = title[title.index("{") + 1:title.rindex("}")].strip()
result = '''import SwiftUI
import NodysseyNativeCore

// Verbatim shipping identity/blocked helpers, initializer and title projection.
@MainActor func actualFloorBlocked(value: JSONValue, opening: Bool,
                                  expanded: Set<String> = []) -> Bool {
    ''' + helpers + '''
    return blocked(value, opening: opening)
}
@MainActor func actualFloorEntry(value: JSONValue, page: Int64, opening: Bool,
                                postID: Int64, threadValue: JSONValue,
                                expanded: Set<String> = []) -> ContentShareLink {
    let thread = NativeStore()
    thread.value = threadValue
    let preview: JSONValue? = nil
    let title = ''' + title_expression + '''
    ''' + helpers + '''
    let selection = (id: identity(value, opening: opening), opening: opening)
    struct Row { let page: Int64 }
    let row: Row? = opening ? nil : Row(page: page)
    return ''' + entry + '''
}
'''
pathlib.Path(sys.argv[1]).write_text(result)
print("Staged exact floorActionSheet share entry, title and blocked/reveal identity (toolbar preserved)")
