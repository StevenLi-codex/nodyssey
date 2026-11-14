#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HERE/Sources"
for file in NativeDestination NativeAppModel NativeStore NativePresentation; do
    if [ -f "$HERE/../Nodyssey/Native/Foundation/$file.swift" ]; then
        cp "$HERE/../Nodyssey/Native/Foundation/$file.swift" "$HERE/Sources/"
    fi
done
for file in EditorState EditorViewModel NativeEditorScreens; do
    cp "$HERE/../Nodyssey/Native/Editing/$file.swift" "$HERE/Sources/"
done
cp "$HERE/../Nodyssey/Native/Rendering/RichDocument.swift" "$HERE/Sources/"
cp "$HERE/../NativeEditorTests/TestSupport/Focus.swift" "$HERE/Sources/"
if [ "$(xcode-select -p)" != /Library/Developer/CommandLineTools ]; then
    swift test --disable-xctest --package-path "$HERE"
    exit 0
fi
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
swift test --disable-xctest --package-path "$HERE" \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
