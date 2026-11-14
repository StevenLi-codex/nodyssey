# Private boundary checkpoint — NOT release acceptance

The opaque String ABI in `swiftui-private-boundary-contract.md` is unchanged. This document retains the earlier private-boundary handoff below as historical evidence, not a current unresolved-issue list. The frozen integration checkpoint additionally contains selective settings redaction/inventory, protected preference compensation, callback-in-lease delivery, joined paging/scheduler tests, coordinator failure recovery, exact public `site.get` bootstrap, and drained `recoveryEligible` recovery. The final two narrow fixes passed an independent 13-case production-bridge JVM graph replay; that replay is not Apple graph execution. The original automatic-deletion reproduction remains preserved and is not a preserve-and-deny acceptance gate.

The full development checkpoint is being committed to the feature branch for real Apple CI. It is **not release acceptance**. No live data was reset and no forum writes were made. Full generated-framework, Xcode compile/link, simulator/runtime and private-store lifecycle acceptance remain separate gates; see `swiftui-private-boundary-contract.md`, `swiftui-private-inventory.md`, `swiftui-private-settings.md` and `swiftui-request-drain.md` for the current contracts.

## Implemented

- Auth-only SHA-256 owner proof in Kotlin, separate from the clearance-sensitive 32-bit session fingerprint. Owner proof is not a native DTO field.
- Versioned Preferences DataStore provenance journal; missing/unknown/interrupted provenance denies access without deleting existing data. Only absent journal plus empty inventory can initialize automatically. Same verified owner survives DataStore close/reopen.
- Joinable nested work leases, admission closure before journal/cleanup, explicit displayed-epoch reset, and deferred session publication after count reset. Optional/default-disabled shared hooks retain legacy Android construction behavior.
- iOS container uses protected draft repositories, `PrivatePostRepository` (including exact network-only `reconcileThreadReactions` delegation), and `PrivateOfflineLibrary`. Raw repository cleanup is reserved for the coordinator after revocation.
- Native request/observe entry points, browser mutation lifecycle, foreground/background/maintenance scheduler launches, Coil interceptor, and native image cache/offline reads enter the boundary. Opt-in Foundation transport lifetime waits terminal callbacks; cancellation may wait for the configured network timeout rather than promptly canceling the task.
- `NativeRequest.invokeOnCompletion` reports actual Job termination via an independent Main callback scope; `cancel()` remains compatible.

## Actual local evidence

- Gradle `:shared:jvmTest --tests '*Private*Boundary*Test' --offline --no-daemon`: 8 tests, zero failures/errors/skips (7 persistence/barrier tests + 1 repository wrapper test).
- `python3 iosapp/tests/private_boundary_test.py`: 7 tests passed; exact shared sources and real temporary DataStore files.
- `python3 iosapp/tests/native_session_security_test.py --repeat 3`: 3 × 16 passed. Final additional single replay: 16 passed.
- `--open-publication`: 1 passed. `--drain`: 1 passed. These are JVM bridge fixtures with a generated graph, not the real Apple graph.
- `python3 iosapp/tests/native_request_completion_test.py`: unchanged concrete suite, 7 passed, zero ignored.
- `python3 iosapp/NativeContentUITests/reaction-repository-regression.py`: 12 real-Room scenario groups passed after wrapper integration.
- `git diff --check`: passed at checkpoint.
- Behavioral RED before wrapper implementation: direct unguarded repository failed denied-admission assertion. Earlier persistence/barrier RED→GREEN details and artifact paths are in the JSON handoff.

## Explicit remaining blockers (not merely Apple gates)

1. `native_session_security_test.py --open-isolation` remains **RED (1 failure)**. Its old fixture constructs an unguarded legacy composer and reads it directly; it expects automatic deletion, conflicting with the newly authorized preserve-and-deny policy. Do not simply remove/greenwash it: replace/add an actual integrated native graph regression asserting deny + preservation + explicit confirmed reset, covering both post and comment drafts and offline state.
2. Public `settings.get`/`settings.observe` currently expose the whole settings snapshot, including `searchHistory`/`recentBoards`. These mixed private/device-global keys require explicit inventory classification and selective redaction/cleanup; do not wipe all settings. `settings.set(readHistoryLimit)` persists the global preference before protected history trim may refuse.
3. Full Room/offline/image inventory cleanup/relaunch is not exercised through the real iOS container. Title-keyword filters, sticker caches and mixed settings keys need a documented classification; current protected inventory covers post/comment drafts, private Room content/profile/history/collection/user notes/tracking/offline rows, offline files, report comparison entries and Coil caches.
4. Native private one-shot result delivery currently occurs after `protect { dispatch() }` returns. Verify/fence the result delivery against a transition in that interval. Observation restart/cancellation and Paging child lifetimes also require integrated controlled-writer tests, not only lease-unit tests.
5. Coordinator failure injection is incomplete: journal/read/publication failures and cancellation during `beginMutation()` must prove counts cannot publish early and retries cannot use the `observed == candidate` shortcut while reconciliation is incomplete. Shared tests cover a cancelled barrier transition but not all coordinator interruption points.
6. Private observations are canceled at revocation; integrated Swift resubscription and empty-state behavior are not established by the shared tests. Scheduler foreground/background restart/join and WebKit cookie terminal-callback behavior remain unexecuted on Apple.

## Exact residual Apple gates

- Build actual Kotlin/Native iOS simulator/device frameworks and compile `iosMain` + `iosTest`; this Linux aarch64 host reports unsupported Kotlin/Native host. No skipped task is evidence of Apple compilation.
- Verify generated Objective-C/Swift exports for String `identityEpoch`, reset/privateBoundary JSON and `NativeRequest.invokeOnCompletion`, then link the real SwiftUI target in full Xcode.
- Run named native completion/security/boundary tests with zero skips, then simulator/device controlled callback tests for NSURLSession cancellation/cookie installation/upload-file lifetime, WebKit seed/drain/close/sign-out, Coil cache/decoder completion and BGTask expiration.
- Run real graph A→B, same-owner relaunch, unknown legacy preserve/deny, interrupted reset and explicit recovery UI tests with temporary test stores. No live-user-data reset is authorized by this checkpoint.

Complete machine-readable handoff: `/home/hermes/.hermes/cache/scratch/nodyssey-private-boundary.json`.
