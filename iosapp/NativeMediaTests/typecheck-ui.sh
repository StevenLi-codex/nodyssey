#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?}/media-typecheck.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
FLAGS="-swift-version 5 -sdk $SDK -target arm64-apple-macos14.0 -module-cache-path $STAGE/cache"
swiftc $FLAGS -emit-module -module-name NodysseyNativeCore "$HERE"/../NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path "$STAGE/NodysseyNativeCore.swiftmodule"
MEDIA="$HERE/../Nodyssey/Native/Media"
# Check the exact gallery region without pulling unrelated auth/configuration screens into this probe.
python3 -c 'import pathlib,sys; source=pathlib.Path(sys.argv[1]).read_text(); marker="struct MediaHostGallery: View {"; assert source.count(marker)==1; pathlib.Path(sys.argv[2]).write_text("import SwiftUI\nimport NodysseyNativeCore\n"+source[source.index(marker):])' "$MEDIA/NativeMediaScreens.swift" "$STAGE/MediaHostGallery.swift"
swiftc $FLAGS -I "$STAGE" -typecheck "$MEDIA/MediaDomain.swift" "$MEDIA/MediaSupport.swift" "$MEDIA/NativeStickerGroup.swift" "$MEDIA/NativeStickerManagement.swift" "$STAGE/MediaHostGallery.swift" "$HERE/Typecheck/MediaContracts.swift"
printf '%s\n' 'Media SwiftUI macOS signature check PASS (compile-only platform boundaries; not iOS/UIKit linkage or appearance).'
