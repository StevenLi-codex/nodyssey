#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
plutil -lint "$HERE"/../Nodyssey/Native/Library/*.lproj/Library.strings
STAGE=$(mktemp -d "${TMPDIR:?}/nodyssey-library-ui.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
swiftc -emit-module -parse-as-library -swift-version 6 -module-name NodysseyNativeCore -sdk "$SDK" -target arm64-apple-macos13.0 -module-cache-path "$TMPDIR/module-cache" -emit-module-path "$STAGE/NodysseyNativeCore.swiftmodule" "$HERE"/../NativeCore/Sources/NodysseyNativeCore/*.swift
swiftc -typecheck -swift-version 6 -sdk "$SDK" -target arm64-apple-macos13.0 -I "$STAGE" -module-cache-path "$TMPDIR/module-cache" "$HERE"/../Nodyssey/Native/Foundation/NativeRefreshState.swift "$HERE"/../Nodyssey/Native/Foundation/NativeRefreshable.swift "$HERE/../Nodyssey/Native/Foundation/NativePressStyle.swift" "$HERE"/../Nodyssey/Native/Library/*.swift "$HERE"/Typecheck/FoundationContract.swift
