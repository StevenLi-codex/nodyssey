#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HERE/Sources"
# Copy the real domain file; a missing file is an API RED, not a runtime assertion.
if [ -f "$HERE/../Nodyssey/Native/Media/MediaDomain.swift" ]; then
    cp "$HERE/../Nodyssey/Native/Media/MediaDomain.swift" "$HERE/Sources/MediaDomain.swift"
else
    touch "$HERE/Sources/Missing.swift"
fi
if [ "$(xcode-select -p)" != /Library/Developer/CommandLineTools ]; then
    swift test --disable-xctest --package-path "$HERE"
    exit 0
fi
DEVELOPER=$(xcode-select -p)
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
swift test --disable-xctest --package-path "$HERE" \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
