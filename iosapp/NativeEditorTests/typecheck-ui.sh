#!/bin/sh
set -eu
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
# Syntax only. CLT has no UIKit/PhotosUI runtime or iOS SDK; do not call this an iOS typecheck.
swiftc -frontend -parse iosapp/Nodyssey/Native/Editing/EditorPhotoPicker.swift iosapp/Nodyssey/Native/Editing/MarkedTextEditor.swift iosapp/NativeEditorTests/UIKit/MarkedEditorTests.swift
swiftc -emit-module -parse-as-library -module-name NodysseyNativeCore -swift-version 6 -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path scratch/ui-modules iosapp/NativeCore/Sources/NodysseyNativeCore/*.swift -emit-module-path scratch/NodysseyNativeCore.swiftmodule
swiftc -typecheck -swift-version 6 -sdk "$SDK" -target arm64-apple-macos14.0 -module-cache-path scratch/ui-modules -I scratch \
 iosapp/Nodyssey/Native/Rendering/*.swift \
 iosapp/Nodyssey/Native/Foundation/NativeDestination.swift iosapp/Nodyssey/Native/Foundation/NativeRefreshCompletion.swift iosapp/Nodyssey/Native/Foundation/NativeStore.swift \
 iosapp/Nodyssey/Native/Editing/EditorState.swift iosapp/Nodyssey/Native/Editing/EditorViewModel.swift \
 iosapp/Nodyssey/Native/Editing/NativeEditorScreens.swift iosapp/Nodyssey/Native/Editing/NativePostComposerPresentation.swift iosapp/Nodyssey/Native/Editing/EditorPanels.swift \
 iosapp/Nodyssey/Native/Editing/EditorMessageThread.swift iosapp/Nodyssey/Native/Editing/EditorThreadReply.swift \
 iosapp/Nodyssey/Native/Editing/EditorRichPreview.swift iosapp/NativeEditorTests/Typecheck/PlatformSignatures.swift
