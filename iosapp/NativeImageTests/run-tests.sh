#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR to your scratch directory}/nodyssey-image.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
cp "$HERE/Boundary.swift" "$STAGE/Sources/Boundary.swift"
PLATFORM="$HERE/../Nodyssey/Native/Platform"
cp "$PLATFORM"/NativeImage*.swift "$STAGE/Sources/"
DEVELOPER=$(xcode-select -p)
if [ "$DEVELOPER" = /Library/Developer/CommandLineTools ]; then
    FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
    PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    swift test --disable-xctest --package-path "$STAGE" \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
else
    swift test --package-path "$STAGE"
fi
