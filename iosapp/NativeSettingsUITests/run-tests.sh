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
printf '%s\n' 'Settings Foundation behavior (base suite)'
DYLD_LIBRARY_PATH="$STAGE" "$STAGE/settings-tests"

# Compile the unchanged production action and gate, not a test reimplementation.
# SETTINGS_ACTION_TESTS in main.swift supplies ONLY a synthetic async app boundary
# and unused UI dependency signatures. Do not link Typecheck/ into this executable.
swiftc -sdk "$SDK" -target arm64-apple-macos13.0 -I "$STAGE" -L "$STAGE" -lNodysseyNativeCore -D SETTINGS_ACTION_TESTS "$ROOT/iosapp/Nodyssey/Native/Settings/SettingsBehavior.swift" "$ROOT/iosapp/Nodyssey/Native/Settings/SettingsComponents.swift" "$HERE/main.swift" -o "$STAGE/settings-action-tests"
printf '%s\n' 'SettingsAction integration (includes base suite; test-only app/UI dependencies, not UI automation)'
DYLD_LIBRARY_PATH="$STAGE" "$STAGE/settings-action-tests"
