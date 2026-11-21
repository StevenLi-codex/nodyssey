#!/bin/sh
# Run only through the authorized mac_light.py staged request, never direct SSH.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/../../.." && pwd)
TEST_STAGE=$(mktemp -d "${TMPDIR:?Use the isolated Mac stage}/nodyssey-preview.XXXXXX")
trap 'rm -rf "$TEST_STAGE"' EXIT HUP INT TERM
mkdir -p "$TEST_STAGE/Sources" "$TEST_STAGE/Tests"
cp "$HERE/../Package.swift" "$TEST_STAGE/Package.swift"
cp -R "$REPO/iosapp/NativeCore/Sources/NodysseyNativeCore" "$TEST_STAGE/Core"
for file in ContentPostPreviewState ContentPostPreviewLoader; do
    cp "$REPO/iosapp/Nodyssey/Native/Content/$file.swift" "$TEST_STAGE/Sources/"
done
for file in NativeStore NativeDestination NativeRefreshCompletion NativeRefreshState; do
    cp "$REPO/iosapp/Nodyssey/Native/Foundation/$file.swift" "$TEST_STAGE/Sources/"
done
cp "$HERE/Boundary.swift" "$TEST_STAGE/Sources/"
cp "$HERE/"*Tests.swift "$TEST_STAGE/Tests/"
cp "$HERE/../Composition/ContentPostPreviewAndBoardSwipeTests.swift" "$TEST_STAGE/Tests/"
swift test --package-path "$TEST_STAGE" --scratch-path "$TEST_STAGE/.build" --disable-xctest
