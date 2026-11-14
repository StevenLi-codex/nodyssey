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
swiftc -typecheck -warnings-as-errors -swift-version 6 -sdk "$SDK" -target arm64-apple-macos13.0 -module-cache-path "$CACHE" -I "$CACHE" "$@" "$HERE/Typecheck/DomainSignatures.swift"
