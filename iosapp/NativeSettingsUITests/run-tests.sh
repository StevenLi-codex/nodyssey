#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
STAGE=$(mktemp -d "${TMPDIR:?}/nodyssey-settings.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
SDK=$(xcrun --sdk macosx --show-sdk-path)
if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -emit-library -emit-module -module-name NodysseyNativeCore -o "$STAGE/libNodysseyNativeCore.dylib" -emit-module-path "$STAGE/NodysseyNativeCore.swiftmodule" "$ROOT"/iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -I "$STAGE" -L "$STAGE" -lNodysseyNativeCore "$ROOT/iosapp/Nodyssey/Native/Settings/SettingsBehavior.swift" "$HERE/main.swift" -o "$STAGE/settings-tests"
DYLD_LIBRARY_PATH="$STAGE" "$STAGE/settings-tests"
