#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR to your scratch directory}/nodyssey-content.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
cp -R "$HERE/../NativeCore/Sources/NodysseyNativeCore" "$STAGE/Core"
cp "$HERE/../Nodyssey/Native/Content/ContentState.swift" "$STAGE/Sources/ContentState.swift"
# CLT-only Macs keep Swift Testing outside SwiftPM's inferred framework path.
if [ "$(uname -s)" = Darwin ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    DEVELOPER=$(xcode-select -p)
    FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
    PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    swift test --disable-xctest --package-path "$STAGE" \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
else
    swift test --package-path "$STAGE"
fi
