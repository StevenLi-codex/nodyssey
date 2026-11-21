# Native Content local gates

On an Apple-toolchain host, set `TMPDIR` to an isolated scratch directory, then run:

```sh
sh iosapp/NativeContentUITests/run-tests.sh
CONTENT_COMPOSITION=1 sh iosapp/NativeContentUITests/run-tests.sh
```

The default entry first runs the existing state suite, then delegates once to
`Preview/run-tests.sh`. The preview leaf does not call its parent. It stages the
production preview state/loader, `NativeStore`, request state and core DTOs with
an explicit controlled transport/app boundary; it does not execute Kotlin,
Room, live networking or UIKit touch delivery. The composition mode separately
compiles the Content/Rendering/Editor tree with its documented test leaves.

The explicit composition/UI-signature source closure includes the actual
`NativeSettingsAppearance`, `SettingsComponents` (which declares
`nativeSettingsAccent`) and `SettingsBehavior`; do not replace those dependencies
with a production stub. `run-mac-tests.py` stages the same dependencies, including
the real Store/Destination needed by the delegated preview leaf. Remote execution
must still use whichever Mac wrapper/authorization applies to the current task.

Count method outcomes, not parameter invocations or Swift Testing's aggregate
"passed" wording. The original default + preview subset contains **97 methods:
95 passed and 2 skipped** when repository-replay input is absent. The three new
read-only remote-preview regressions bring the current default entry to **100
methods: 98 passed and 2 skipped**. A skipped repository-replay test is not proof
that the Kotlin repository ran. Compiler failure is not behavioral RED, and a
SwiftUI/macOS signature check is not an iOS hit/menu/gesture acceptance result.

The UIKit-only regression in `UIKit/PreviewCoordinatorTests.swift` runs against
`ContentPostPreviewInteraction.Coordinator` and real public UIKit interaction/
animator protocols in a separate iOS XCTest target. It replays animator callbacks
programmatically; it does not send touch events. Keep hit geometry diagnostics
and presentation scaffolding out of the committed logic suite. Its app/transport
boundary must explicitly provide current Home/root/session eligibility.

Preview reads a complete cached opening body first. A cache miss or null body
uses the iOS `thread.preview(postId)` page-one read, not `thread.load`; the latter
can mutate the repository's cache window. The Swift transport tests establish
publication/cancellation fencing only. Backend non-mutation and genuine iOS
preview presentation require their own execution evidence.
