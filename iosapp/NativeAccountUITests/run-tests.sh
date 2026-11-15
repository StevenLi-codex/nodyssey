#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?}/account-tests.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Test/Sources"
cp "$HERE/Package.swift" "$STAGE/Test/"
cp -R "$HERE/Tests" "$STAGE/Test/"
cp -R "$HERE/../NativeCore" "$STAGE/NativeCore"
for FILE in "$HERE"/../Nodyssey/Native/Account/*State.swift; do
 [ ! -f "$FILE" ] || cp "$FILE" "$STAGE/Test/Sources/"
done
cp "$HERE/../Nodyssey/Native/Account/AccountProfileDate.swift" "$STAGE/Test/Sources/"
touch "$STAGE/Test/Sources/Empty.swift"
if [ "$(xcode-select -p)" != /Library/Developer/CommandLineTools ]; then
    swift test --disable-xctest --package-path "$STAGE/Test"
    exit 0
fi
DEVELOPER=$(xcode-select -p)
FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
swift test --disable-xctest --package-path "$STAGE/Test" -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xswiftc -load-plugin-library -Xswiftc "$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
