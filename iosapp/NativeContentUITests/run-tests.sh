#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?Set TMPDIR to your scratch directory}/nodyssey-content.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/Sources"
cp "$HERE/Package.swift" "$STAGE/Package.swift"
cp -R "$HERE/Tests" "$STAGE/Tests"
cp -R "$HERE/../NativeCore/Sources/NodysseyNativeCore" "$STAGE/Core"
cp "$HERE/../Nodyssey/Native/Content/ContentState.swift" "$STAGE/Sources/ContentState.swift"
cp "$HERE/../Nodyssey/Native/Content/ContentFeedTopRefresh.swift" "$STAGE/Sources/ContentFeedTopRefresh.swift"
cp "$HERE/../Nodyssey/Native/Content/ContentCommand.swift" "$STAGE/Sources/ContentCommand.swift"
cp "$HERE/../Nodyssey/Native/Content/ContentImageGallery.swift" "$STAGE/Sources/ContentImageGallery.swift"
cp "$HERE/../Nodyssey/Native/Content/ContentPreferences.swift" "$STAGE/Sources/ContentPreferences.swift"
# Compose the actual Content/Rendering tree; only platform/bridge and terminal
# source leaves use executable probes (never the signature-only fixtures).
if [ "${CONTENT_COMPOSITION:-0}" = 1 ]; then
    cp "$HERE/../Nodyssey/Native/Foundation/NativePageCanvas.swift" "$STAGE/Sources/"
    cp "$HERE/../Nodyssey/Native/Foundation/NativeGlassSurface.swift" "$STAGE/Sources/"
    for file in NativeHomeTabInteraction NativeRefreshState NativeRefreshCompletion NativeRefreshable NativePostTransition NativePressStyle; do
        cp "$HERE/../Nodyssey/Native/Foundation/$file.swift" "$STAGE/Sources/"
    done
    cp "$HERE/../Nodyssey/Native/Content/"*.swift "$STAGE/Sources/"
    cp "$HERE/../Nodyssey/Native/Sharing/"*.swift "$STAGE/Sources/"
    for source in "$HERE/../Nodyssey/Native/Rendering/"*.swift; do
        [ "$(basename "$source")" = NativeCodeBlock.swift ] || cp "$source" "$STAGE/Sources/"
    done
    for file in EditorState EditorViewModel NativeEditorScreens NativePostComposerPresentation EditorPanels EditorMessageThread EditorRichPreview EditorThreadReply; do
        cp "$HERE/../Nodyssey/Native/Editing/$file.swift" "$STAGE/Sources/"
    done
    for file in AccountAuthorQuickCard AccountAuthorQuickCardState AccountProfileDate; do
        cp "$HERE/../Nodyssey/Native/Account/$file.swift" "$STAGE/Sources/"
    done
    cp "$HERE/Typecheck/ThreadEditorContracts.swift" "$STAGE/Sources/"
    cp "$HERE/CompositionSupport/"*.swift "$STAGE/Sources/"
    cp "$HERE/Composition/"*.swift "$STAGE/Tests/"
fi
# CLT-only Macs keep Swift Testing outside SwiftPM's inferred framework path.
if [ "$(uname -s)" = Darwin ] && [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ]; then
    DEVELOPER=$(xcode-select -p)
    FRAMEWORKS="$DEVELOPER/Library/Developer/Frameworks"
    PLUGIN="$DEVELOPER/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    swift test --disable-xctest --package-path "$STAGE" --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
else
    swift test --package-path "$STAGE"
fi
