#!/bin/sh
# macOS-only behavioral composition: real renderer, no network/image requests.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR}/nodyssey-composition.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources" "$STAGE/Tests"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp "$HERE/../Nodyssey/Native/Rendering/"*.swift "$STAGE/Sources/"
cp "$HERE/Composition/"*.swift "$STAGE/Tests/"
cp "$HERE/TestSupport/NativeRemoteImage.swift" "$STAGE/Sources/"
DEVELOPER=$(xcode-select -p)
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
# The installed newer SDK references a missing CLT SwiftUI macro plugin.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swift test --disable-xctest --package-path "$STAGE" --sdk "$SDK" \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
