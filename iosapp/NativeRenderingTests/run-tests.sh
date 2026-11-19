#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR to your scratch directory}/nodyssey-rendering.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
SOURCE="$HERE/../Nodyssey/Native/Rendering/RichDocument.swift"
cp "$SOURCE" "$STAGE/Sources/RichDocument.swift"
cp "$HERE/../Nodyssey/Native/Rendering/NativeRenderingMemo.swift" "$STAGE/Sources/"
cp "$HERE/../Nodyssey/Native/Rendering/NativeInlineArrangement.swift" "$STAGE/Sources/"
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
