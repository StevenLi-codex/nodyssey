#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR to a scratch directory}/nodyssey-sharing.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
cp -R "$HERE/../NativeCore/Sources/NodysseyNativeCore" "$STAGE/Core"
cp "$HERE/../Nodyssey/Native/Rendering/RichDocument.swift" "$STAGE/Sources/"
cp "$HERE/../Nodyssey/Native/Content/ContentShareLink.swift" "$STAGE/Sources/"
# Signature-only dependencies trap if invoked; no native bridge or site request runs.
cp "$HERE/../NativeContentUITests/Typecheck/Contracts.swift" "$STAGE/Sources/"
cp "$HERE/../Nodyssey/Native/Foundation/NativeRefreshCompletion.swift" "$STAGE/Sources/"
python3 "$HERE/stage-floor-entry.py" "$STAGE/Sources/ActualFloorEntry.swift"
for file in "$HERE/../Nodyssey/Native/Sharing/"*.swift; do
    [ ! -f "$file" ] || cp "$file" "$STAGE/Sources/"
done
if [ "$(uname -s)" = Darwin ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    DEVELOPER=$(xcode-select -p)
    SDK="$DEVELOPER/SDKs/MacOSX26.5.sdk"
    FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
    PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    swift test --disable-xctest --sdk "$SDK" --package-path "$STAGE" \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
else
    swift test --package-path "$STAGE"
fi
