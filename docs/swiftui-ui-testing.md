# Native navigation acceptance (XCUITest)

## Latest interrupted rerun

Run `43575181746` at `cc2f4ddc83fe2926b7c093ca9b5d159c92e649c8` ended **cancelled**, not passed. Downloaded job metadata confirms Swift domain tests, Kotlin compilation and simulator app build succeeded. The Kotlin execution log reports **54 tests completed, 1 failed**, identifying `WebKitSvgRasterizerTest`; this is a log-level count, not a newly parsed XML acceptance result. App-hosted comparison was cancelled; launch and navigation steps were skipped. Therefore this run provides **no execution verdict for the corrected Profile navigation assertions**. Evidence: `/home/hermes/.hermes/cache/scratch/nodyssey-ci-43575181746/`. The newer image-host checkpoint is covered by separate run `43577393525`; do not transfer this cancelled run's results to that SHA.

## Integration requirements

`NativeNavigationUITests` launches the real `Nodyssey` application and existing Kotlin-backed graph. No mocks, direct route arguments, test-only root, onboarding preference injection, credential entry or server mutations. Failed guest feed/notification requests are allowed; navigation must remain interactive.

The production controls need these accessibility identifiers (do not replace their real actions for testing):

| Owner | Identifier | Contract |
| --- | --- | --- |
| Foundation | `native.root` | Native app shell, not Compose |
| Foundation | `native.tab.home`, `native.tab.notifications`, `native.tab.profile` | Actual tappable tab controls, including while Settings is pushed |
| Foundation | `native.screen.PostList`, `.Notifications`, `.Profile`, `.Settings`, `.SignIn` | `native.screen.<route>` identifies the routed screen; preserve child accessibility. Profile reachability additionally requires both real guest actions below, not a hit point on its List container. |
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

## Integrated app failure diagnosis and pending rerun

Run `43565737701`, commit `6a171529d43efb38bfde7fd71e932685ad1ff31b`, built and launched the complete SwiftUI app using Xcode 26.6 / iPhone 17 Pro simulator (iOS 26.4.1). All **3 real navigation tests failed at the first Profile screen check**; Home and Notifications checks reached their content. This is different from the earlier old-root startup failure.

The downloaded artifact `14103077365` contains the actual `NativeNavigation.xcresult`. Its failure element descriptions resolve `native.screen.Profile` to a full-screen `CollectionView`, while the query hierarchy shows `native.tab.profile` **Selected**, `native.profile.signin`, and `native.profile.settings`. There are 22 complete hierarchy snapshots across the three test app PIDs with this state; two additional partial element descriptions do not contain the full query output. The three failure screenshot attachments reference two distinct PNG payloads, both showing the unobstructed guest My space screen with Me selected. These establish that route selection and rendering occurred, **not** that either action was tapped successfully. The old assertion stopped before those taps.

The confirmed failing predicate was the generic screen container's `exists && isHittable`. Apple's [`isHittable`](https://developer.apple.com/documentation/xcuiautomation/xcuielement/ishittable) asks whether a hit point can be computed; it is not a general screen-visibility assertion. `NativeScreen` attaches `.accessibilityElement(children: .contain)` to the domain `AnyView`; Apple's [contain contract](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/contain) allows modification of an existing accessibility element rather than creation of a new wrapper. In this run the marker is on the List CollectionView. The precise SwiftUI/UIKit reason that container lacks a hit point remains unproven; neither a navigation reset nor combined/hidden guest actions is established by these failures. No production wrapping, hit-test overlay, route bypass or account-domain change was made to force a green marker.

The test now requires Profile's route identity **plus both real guest action hit points**, and verifies the actual selected tab on every tab transition. It also checks that Profile actions are not hittable in Home/Notifications and that returning to Profile restores reachability. Existing Settings push/preservation and sign-in open/cancel/reopen checks remain real taps, with no skips or credential input. The other screen hit-point checks remain unchanged; failure there must be diagnosed from the next result, not preemptively waived. Failure attachments now include the full application accessibility hierarchy as well as the screenshot.

Verification of this edit: the existing approved Mac structural validator and Swift parser exited 0, but XCTest APIs and iOS execution are **not** verified on that CLT-only host. A full Xcode rerun must execute all three tests with zero failures/skips and retain its xcresult before calling this navigation GREEN. No current iOS pass is claimed.

### Separate confirmed FA5 lifecycle defect — backend contract required

`SessionRepository.sync()` increments its reload `generation` when `hasClearance` changes, even with unchanged fingerprint/sign-in status (`shared/.../SessionRepository.kt:65–75,132–138`). `NativeAppModel.session.didSet` treats that counter as identity and invokes `invalidateSession()`: all paths/sheets are cleared and local `app.generation` increments, remounting tabs and restarting editor tasks. This is a real defect, but **not evidence for the Profile test failure above**.

The exported `SessionState.accountDto()` currently exposes only `isSignedIn`, `hasClearance`, and `generation`. Swift cannot safely decide whether a signed-in→signed-in transition is clearance-only or account A→B. Do not use equal `isSignedIn` booleans, a change in `hasClearance`, or guessed profile UID to suppress invalidation.

Required coordinated bridge contract before the production fix:

- Add an authoritative opaque `identityEpoch` (proposed name, exact JSON integer/Int64), scoped to the running graph/site. Compare only for equality; never export cookie values, the cookie fingerprint, or a hash derived from secrets.
- Keep it stable for clearance-only refresh/reload changes; change it for actual authentication identity replacement, sign-out and supersession, including signed-in A→B. Computing this belongs in the shared/bridge identity owner, not Swift. Site changes and null/revoked sessions must still fail closed.
- Include the same epoch consistently in `session.state`, `session.snapshot`, `session.sync`, sign-in/2FA/sign-out responses (including nested `session`), from an atomic authoritative snapshot. A peek must not pair a new account with an old epoch.
- Retain the existing reload `generation` separately. Swift's path/editor identity and privacy invalidation must follow the identity epoch, while clearance-dependent content retry must not remount the shell or discard editor state. Missing/invalid identity epoch must not silently become "same identity".

The unrealistic clearance test was corrected to advance shared generation 1→2 and preserve the PostComposer path, Profile Settings path, challenge sheet, selected tab and local UI identity. Real Mac execution now produces **14 passing tests and 1 failing test (4 assertion failures)**: both paths are emptied, sheet becomes nil, and local generation changes. The existing signed-in→signed-in account-generation test still passes and must remain an invalidation gate once the new epoch is added. This is deliberately retained **RED**, not skipped or weakened; the production fix is blocked on the backend contract. No Kotlin or production Foundation file was changed.

Evidence files for this diagnosis live under `/home/hermes/.hermes/cache/scratch/`: `nodyssey-ci-43565737701/artifacts/_temp/NativeNavigation.xcresult`, `nodyssey-ci-43565737701/artifacts/_temp/navigation-decoded/`, `nodyssey-navigation-structural-validation.log`, `nodyssey-navigation-foundation-tests.log` (original fixture, 15 pass), and `nodyssey-navigation-fa5-red.log` (corrected fixture, 1 fail). CLT linker search-path and Testing deployment-target warnings are present; these are not clean iOS build logs.

## Original delegated verification status

Tests were written before adding the Xcode target. No behavioral RED/GREEN run is available on the delegated machine: Linux has no `xcodebuild`, and the approved remote Mac has Command Line Tools only. This is an explicit blocked runtime gate, not a successful TDD cycle. Parent CI must compile/link the complete app, discover all three XCUITests, execute them on the simulator and retain the actual result bundle before claiming native navigation acceptance.

Executed `python3 iosapp/NativeNavigationUITests/run-mac-validation.py` over the existing approved nested SSH route. On the real Mac:

- `plutil -lint` accepted the actual edited `project.pbxproj`.
- `plutil -convert json` plus `validate-project.py` resolved target/product/source/dependency/configuration edges and shared-scheme XML references, and checked preservation of the synchronized Native group, NativeCore package and Kotlin host build phase.
- `swiftc -frontend -parse -swift-version 5` accepted the test source syntax only (XCTest APIs were **not** typechecked).
- `xcode-select -p` returned `/Library/Developer/CommandLineTools`; `xcodebuild -version` failed: `tool 'xcodebuild' requires Xcode`.

The validation script returns success for its narrow structural checks and explicitly prints `RUNTIME BLOCKED`; it is **not** the acceptance command. It stages only the project, scheme, test source and structural validator in an isolated Mac cache, not a buildable full checkout. Local `git diff --check` also passed. Plist/XML parsing, object-graph checks and Swift parsing prove neither Xcode project loading nor iOS compilation, XCTest discovery, application launch, or successful UI behavior.
