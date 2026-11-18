#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HERE/Sources"
trap 'rm -rf "$HERE/Sources"' EXIT HUP INT TERM
cp "$HERE/../Nodyssey/Native/Editing/EditorState.swift" "$HERE/Sources/"
cp "$HERE/../Nodyssey/Native/Editing/EditorViewModel.swift" "$HERE/Sources/"
cp "$HERE/../Nodyssey/Native/Rendering/RichDocument.swift" "$HERE/Sources/"
cp "$HERE/../Nodyssey/Native/Media/MediaDomain.swift" "$HERE/Sources/"
cp "$HERE/TestSupport/Focus.swift" "$HERE/Sources/"
if [ "$(xcode-select -p)" != /Library/Developer/CommandLineTools ]; then
    swift test --disable-xctest --package-path "$HERE"
    exit 0
fi
D=$(xcode-select -p)
F="$D/Library/Developer/Frameworks"
swift test --disable-xctest --package-path "$HERE" -Xswiftc -F -Xswiftc "$F" -Xswiftc -load-plugin-library -Xswiftc "$D/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" -Xlinker -rpath -Xlinker "$F" -Xlinker -F -Xlinker "$F"
