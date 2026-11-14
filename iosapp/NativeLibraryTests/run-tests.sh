#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?}/nodyssey-library.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
cp -R "$HERE/../NativeCore/Sources/NodysseyNativeCore" "$STAGE/Core"
cp "$HERE/../Nodyssey/Native/Library/LibraryBehavior.swift" "$STAGE/Sources/"
if [ "$(uname -s)" = Darwin ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
 DEVELOPER=$(xcode-select -p)
 FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
 swift test --disable-xctest --package-path "$STAGE" -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xswiftc -load-plugin-library -Xswiftc "$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
else
 swift test --package-path "$STAGE"
fi
