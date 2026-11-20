#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE="${TMPDIR:?}/foundation-typecheck"
mkdir -p "$CACHE"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [ ! -d "$SDK" ]; then SDK=$(xcrun --sdk macosx --show-sdk-path); fi
swiftc -emit-module -module-name NodysseyNativeCore -swift-version 6 -sdk "$SDK" -target arm64-apple-macos13.0 -module-cache-path "$CACHE" "$HERE"/../NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path "$CACHE/NodysseyNativeCore.swiftmodule"
set --
for file in "$HERE"/../Nodyssey/Native/Foundation/*.swift; do
    case "$file" in */NativeClient.swift) continue;; esac
    set -- "$@" "$file"
done
swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$SDK" -target arm64-apple-macos13.0 -module-cache-path "$CACHE" -I "$CACHE" "$@" "$HERE/../Nodyssey/Native/Settings/SettingsBehavior.swift" "$HERE/../Nodyssey/Native/Settings/SettingsComponents.swift" "$HERE/Typecheck/DomainSignatures.swift"
echo 'Foundation strict SwiftUI signatures passed; checking real Editor route wiring (platform signatures only)'
swiftc -typecheck -swift-version 6 -D FOUNDATION_EDITOR_UI_CHECK -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path "$CACHE" -I "$CACHE" "$@" \
    "$HERE/../Nodyssey/Native/Settings/SettingsBehavior.swift" "$HERE/../Nodyssey/Native/Settings/SettingsComponents.swift" \
    "$HERE/Typecheck/DomainSignatures.swift" "$HERE/Typecheck/EditorPlatformSignatures.swift" \
    "$HERE"/../Nodyssey/Native/Rendering/*.swift \
    "$HERE/../Nodyssey/Native/Editing/EditorState.swift" "$HERE/../Nodyssey/Native/Editing/EditorViewModel.swift" \
    "$HERE/../Nodyssey/Native/Editing/NativeEditorScreens.swift" "$HERE/../Nodyssey/Native/Editing/NativePostComposerPresentation.swift" "$HERE/../Nodyssey/Native/Editing/EditorPanels.swift" \
    "$HERE/../Nodyssey/Native/Editing/EditorMessageFollowState.swift" "$HERE/../Nodyssey/Native/Editing/EditorMessageThread.swift" "$HERE/../Nodyssey/Native/Editing/EditorRichPreview.swift"
