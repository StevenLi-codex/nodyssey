# Native navigation acceptance (XCUITest)

## Integration requirements

`NativeNavigationUITests` launches the real `Nodyssey` application and existing Kotlin-backed graph. No mocks, direct route arguments, test-only root, onboarding preference injection, credential entry or server mutations. Failed guest feed/notification requests are allowed; navigation must remain interactive.

The production controls need these accessibility identifiers (do not replace their real actions for testing):

| Owner | Identifier | Contract |
| --- | --- | --- |
| Foundation | `native.root` | Native app shell, not Compose |
| Foundation | `native.tab.home`, `native.tab.notifications`, `native.tab.profile` | Actual tappable tab controls, including while Settings is pushed |
| Foundation | `native.screen.PostList`, `.Notifications`, `.Profile`, `.Settings`, `.SignIn` | `native.screen.<route>` wrapper for the current screen; preserve child accessibility; active screen must be reachable |
| Account | `native.profile.settings`, `native.profile.signin` | Actual profile navigation actions; sign-in present for a guest |
| Account | `native.signin.account`, `native.signin.password` | Real form fields; tests never type into them |
| **Account / sheet owner: requested** | **`native.signin.cancel`** | Real cancel/close action, dismissing SignIn back to the originating tab without authenticating |
| **Onboarding owner: requested if startup blocks tabs** | **`native.onboarding.continue`** | Real final guest continue/dismiss action; tests tap it, never bypass onboarding. If onboarding is multi-step, extend the test to perform the actual sequence rather than mapping this identifier to a bypass. |

Identifier assertions are transition observations, not wording/style tests. The tests tap real controls and check consequences: each tab reaches its own root; Profile→Settings survives Home/Notifications round trips without contaminating those stacks; sign-in can cancel and reopen, then normal navigation remains usable. They do not establish all-route acceptance or prove preservation of simultaneous deep stacks in every tab.

Use a dedicated fresh simulator with no signed-in account. Do not run on a personal simulator. Missing identifiers, blocked onboarding, missing native integration or authentication-required tab roots must **fail**, not skip. No screenshot goldens: failure screenshots are evidence attachments only and contain guest UI.

## Target and build boundary

The shared `Nodyssey` scheme includes the independent native `NativeNavigationUITests` UI-testing bundle, with `TEST_TARGET_NAME = Nodyssey`, a dependency on the app, iOS 16 minimum, generated test Info.plist, and simulator signing disabled. It is not `:iosapp:iosSimulatorArm64Test` and does not execute Kotlin test sources. Building its real host still runs the existing Gradle framework/resource build phase; do not disable that phase to obtain a superficial test pass. The synchronized `Native` group and local `NativeCore` package remain attached to the app only.

## Full Xcode / CI gate

Run from repository root on **Apple Silicon macOS with full Xcode 27+**, installed iOS simulator runtime, JDK 21 and the existing repository Gradle/SDK prerequisites. The project already excludes x86_64 simulators. Select the installed Xcode with `DEVELOPER_DIR` only if needed; do not point it at a nonexistent default path.

Create a dedicated simulator from an installed device/runtime pair (`xcrun simctl list devices available`, `xcrun simctl list runtimes`). Set `SIMULATOR_UDID` to that disposable device, not a personal device. The commands below erase its data deliberately:

```bash
set -euo pipefail
: "${SIMULATOR_UDID:?Set a dedicated disposable iOS simulator UDID}"
xcodebuild -version
xcodebuild -list -project iosapp/Nodyssey.xcodeproj
xcrun simctl shutdown "$SIMULATOR_UDID" || true
xcrun simctl erase "$SIMULATOR_UDID"
xcrun simctl boot "$SIMULATOR_UDID"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
mkdir -p build/native-navigation
xcodebuild test \
  -project iosapp/Nodyssey.xcodeproj \
  -scheme Nodyssey \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -destination-timeout 120 \
  -derivedDataPath build/native-navigation/DerivedData \
  -resultBundlePath "build/native-navigation/Navigation-$(date +%Y%m%d-%H%M%S).xcresult" \
  -only-testing:NativeNavigationUITests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
./gradlew --stop
```

Preserve the `.xcresult` even on failure. CI should stop Gradle in its always-run cleanup step. An alternative split invocation uses **the same arguments** with `build-for-testing`, followed by `test-without-building` (set the result bundle path only for the latter). Do not call `test-without-building` against unrelated/stale DerivedData. No retries should hide a failed first acceptance run.

## Parent Apple CI execution

Run `43558825991` at `d30f9e8ec7e60eafebb11d879923f04c48b468c0` built and launched the actual app, compiled the UI test target, and executed all **3 XCUITests: 3 failed**. Each failed the startup wait: `Neither native tabs nor the real onboarding action became available`. The revision still used the old application entry; the complete SwiftUI entry and page domains were not committed in this run. This is a genuine behavioral RED, not navigation acceptance. It closes the earlier test-target compilation/discovery uncertainty only.

Evidence: `native/14_Execute real native navigation tests.txt` and the uploaded `NativeNavigation.xcresult` under `/home/hermes/.hermes/cache/scratch/nodyssey-ci-43558825991/`. The next integrated application must run these unchanged behavioral checks successfully; do not skip the startup assertion or replace the real root to obtain green.

## Original delegated verification status

Tests were written before adding the Xcode target. No behavioral RED/GREEN run is available on the delegated machine: Linux has no `xcodebuild`, and the approved remote Mac has Command Line Tools only. This is an explicit blocked runtime gate, not a successful TDD cycle. Parent CI must compile/link the complete app, discover all three XCUITests, execute them on the simulator and retain the actual result bundle before claiming native navigation acceptance.

Executed `python3 iosapp/NativeNavigationUITests/run-mac-validation.py` over the existing approved nested SSH route. On the real Mac:

- `plutil -lint` accepted the actual edited `project.pbxproj`.
- `plutil -convert json` plus `validate-project.py` resolved target/product/source/dependency/configuration edges and shared-scheme XML references, and checked preservation of the synchronized Native group, NativeCore package and Kotlin host build phase.
- `swiftc -frontend -parse -swift-version 5` accepted the test source syntax only (XCTest APIs were **not** typechecked).
- `xcode-select -p` returned `/Library/Developer/CommandLineTools`; `xcodebuild -version` failed: `tool 'xcodebuild' requires Xcode`.

The validation script returns success for its narrow structural checks and explicitly prints `RUNTIME BLOCKED`; it is **not** the acceptance command. It stages only the project, scheme, test source and structural validator in an isolated Mac cache, not a buildable full checkout. Local `git diff --check` also passed. Plist/XML parsing, object-graph checks and Swift parsing prove neither Xcode project loading nor iOS compilation, XCTest discovery, application launch, or successful UI behavior.
