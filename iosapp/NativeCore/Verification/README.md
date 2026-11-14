# Executed verification — synthetic transports only

Host: arm64 macOS 27.3; Apple Swift 6.4.2; Command Line Tools only.
Remote package staging: `/Users/steven/.cache/hermes-build/nodyssey-native-core`.
No iOS build, Kotlin linkage, UI, device, simulator, account or live-network validation is implied.

## Final gates

- `NATIVE_CORE_TESTING_FROM_SOURCE=1 swift test --disable-xctest`
  - Default SwiftBuild engine, exit 0.
  - `✔ Test run with 20 tests passed after 0.006 seconds.`
  - Full final output: `24-final-swift-test.log`.
- `swift build --build-system native --target NodysseyNativeCore -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors`
  - Exit 0; production module passes Swift 6 strict concurrency and compiler warnings-as-errors.
  - Full output: `23-swift6-build.log`. SwiftPM emits an engine-deprecation warning, not a compiler warning.

## Test-first execution sequence

New API tests initially failed compilation because their symbols did not yet exist; these are
API-absence checks, not claimed runtime assertion failures. Each corresponding suite was then
compiled and executed on the Mac. Existing implementation was never hidden to manufacture RED.

| Slice | Initial failure before implementation | Executed green |
| --- | --- | --- |
| Recursive JSON | `cannot find 'JSONValue' in scope` | 1 test |
| Strict IDs/envelopes | missing `NativeFailure`, `NativeEnvelope`, `requireInt` | 3 tests |
| Callback transport | missing `NativeCancellation`, `CallbackNativeTransport` | 7 tests |
| Latest request/account fencing | missing `NativeRequestState` | 10 tests |
| Mutation/draft state | missing `NativeMutationState` | 13 tests |
| Exact deep links | missing `NativeDeepLink` | 16 tests |
| Observation state notifications | missing `onChange`, `observe` | 17 tests |

Behavioral regressions were then driven by **actual executed failing assertions**, followed by fixes:

- `19-regression-red.log`: invalidation emitted the previous account snapshot before clearing it;
  edit→restore during submission erased the new draft. 19 tests, 2 issues.
- After clearing data before notification and tracking draft revision: 19 tests passed.
- `21-url-red.log`: percent-encoded hosts (`%6eodeseek.com`, `nodeseek%2ecom`) became native routes.
  20 tests, 2 issues.
- After requiring the encoded authority to equal the allowed host: 20 tests passed.

Only concise gate and assertion-failure logs are retained; intermediate repeated compiler diagnostics
and dependency-build progress were discarded.

## CLT-only runner prerequisite

The initial runner attempts failed because this CLT installation has neither XCTest nor bundled
Testing. Source `swift-testing` 6.0.3 was selected for its iOS 13/macOS 10.15 minimums (newer 6.4.2
requires iOS 17/macOS 14). Its exact upstream revision is pinned in the optional manifest branch.
A version-tag dependency was rejected for upstream unsafe build flags; the immutable revision
reference is permitted by SwiftPM. Transitive SwiftSyntax resolved to 600.0.1.

`NATIVE_CORE_TESTING_FROM_SOURCE=1` opts into this **test-only** dependency. Production library
has Foundation only and zero package dependencies by default. Full-Xcode/new Swift toolchains
with bundled Testing can use `swift test` without the opt-in. Tests themselves require Swift Testing.

Initial default-engine clean build had CLT missing-framework search-path linker warnings; all
20 tests still executed successfully. The final incremental default-engine run had no warnings.
