#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=$(mktemp -d "${TMPDIR:?}/account-typecheck.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
FLAGS="-swift-version 5 -sdk $SDK -target arm64-apple-macos14.0 -module-cache-path $STAGE/cache"
swiftc $FLAGS -emit-module -module-name NodysseyNativeCore "$HERE"/../NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path "$STAGE/NodysseyNativeCore.swiftmodule"
swiftc $FLAGS -emit-module -module-name UIKit "$HERE/Typecheck/UIKit.swift" -emit-module-path "$STAGE/UIKit.swiftmodule"
swiftc $FLAGS -emit-module -module-name NodysseyShell "$HERE/Typecheck/NodysseyShell.swift" -emit-module-path "$STAGE/NodysseyShell.swiftmodule"
swiftc $FLAGS -I "$STAGE" -typecheck "$HERE/../Nodyssey/Native/Foundation/NativePageCanvas.swift" "$HERE/../Nodyssey/Native/Foundation/NativeRefreshState.swift" "$HERE/../Nodyssey/Native/Foundation/NativeRefreshable.swift" "$HERE/../Nodyssey/Native/Foundation/NativePressStyle.swift" "$HERE"/../Nodyssey/Native/Account/*.swift "$HERE"/../Nodyssey/Native/Rendering/*.swift "$HERE/Typecheck/AccountContracts.swift" "$HERE/Typecheck/AuthPresentationContracts.swift"
printf '%s\n' 'Account UI macOS signature check PASS (not iOS/UIKit/Kotlin linkage).'
