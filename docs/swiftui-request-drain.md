# Native request termination / editor file ownership

## Cross-owner ABI (implemented in Swift and Kotlin source)

Keep `NativeBridge.request(operation:argumentsJson:completion:)` unchanged. Add to its returned `NativeRequest`:

```kotlin
fun invokeOnCompletion(completion: () -> Unit)
```

Expected exported Swift selector: `handle.invokeOnCompletion(completion: { ... })`.
Register via `Job.invokeOnCompletion` (normal completion, not on-cancelling); invoke exactly once for each registration, including registration after termination. Kotlin dispatches the callback on Main using an independent supervisor scope, never the cancelled request scope. It means the **whole Job including structured children and finally blocks has terminated**. Neither JSON result delivery nor `cancel()` returning establishes this boundary. Do not launch an unstructured child that still consumes the file beyond this Job.

Swift `NativeClient` registers this callback on MainActor immediately after obtaining the handle, before returning its cancellation handle. The callback itself is thread-safe and separate from the UI JSON continuation; cancellation still resumes Swift UI promptly and schedules Kotlin cancellation on MainActor. No sleep, fake join, or result-callback-as-drain.

## Swift contract

`NativeTransport.request(_:_:onTermination:)` carries a separate lifetime callback. Existing transports remain source-compatible; its default implementation delegates the ordinary request but **never acknowledges termination**. Callers must retain leased files if a transport cannot prove termination. `CallbackNativeTransport` adds an explicit drain-aware request-start initializer while retaining its existing initializer for non-file consumers. Only a real platform termination callback (or proof that dispatch never occurred) releases a consumer lease.

Editor attachment leases outlive UI cancellation and route invalidation. Deletion is requested on removal/teardown, but the source is unlinked only after every upload attempt has acknowledged termination. A result can arrive before `finally`; successful completion does not release the lease early. Unknown-drain transports deliberately retain files (safe leak, not a fabricated completion).

## Coordination / open gates

- Kotlin owner owns NativeBridge.kt; Swift owner does not edit Kotlin.
- Foundation route owner owns NativeEditorScreens/navigation; this change does not alter those files.
- Kotlin owner implemented the exact method in `NativeBridge.kt`, with `Job.invokeOnCompletion` dispatching on a separate Main supervisor scope. Generated Objective-C export/Swift selector and actual linked Apple execution are still pending; source agreement is not ABI verification.
- Apple build/link and real preparer ordering remain separate gates; synthetic callback tests do not constitute an upload or Apple integration proof.

## Executed Swift regression gates

- Mac CLT Swift 6.4.2: the original bug reproduced before the fix (`callbackCancellationWithoutDrainRetainsSource`: file was already deleted after the cancelled Swift task unwound). The new drain initializer initially produced a missing-API compiler failure, separately recorded rather than called a behavioral RED.
- `NativeEditorTests/run-tests.sh`: 38 tests passed, including production callback adapter tests for independent reader termination, model deallocation, normal result-before-finally, removal before/after drain, active removal, handle-install race, retry with an older attempt still draining, late generation completion, and fail-closed legacy transports.
- `NativeCore` Swift Testing: 25 tests passed, including cancellation before dispatch/handle installation, synchronous result delivery, late result suppression, idempotent termination, and failure-result-before-finally.
- NativeCore production target compiled in Swift 6 mode with compiler warnings-as-errors. CLT/SwiftBuild emits existing linker search-path warnings and a language-mode override warning; this is not a pristine full-Xcode build.

Standalone Editor verification after the Foundation route-departure integration:

```sh
python3 iosapp/NativeEditorTests/run-mac-tests.py
python3 iosapp/NativeEditorTests/run-mac-tests.py --typecheck-ui
```

Both commands passed on Mac CLT Swift 6.4.2 (38 runtime tests; standalone signature check exit 0). Each invocation now prints and uses a unique Mac staging directory, including its scratch/module cache, so concurrent gates cannot replace staged sources. The compile-only Foundation adapter mirrors `registerDismissal`, `dismissDestination`, `departureRunning` and `EnvironmentValues.nativeDestinationID`; newly added bodies trap if executed, rather than simulate route ownership. The original Editor typecheck/parse source list and runtime tests are unchanged. Existing macOS `onChange` deprecations and CLT linker search-path warnings remain. This is not UIKit runtime, iOS/Kotlin linking, or live upload verification; the real Foundation+Editor route gate remains separate.

The lifetime tests run the actual Swift editor and `CallbackNativeTransport` with synthetic platform handles and local fixture files. No live upload occurs. `close()` awaits UI-task teardown but need not block navigation waiting for an unresponsive reader: the termination callback retains the source-file lease independently, and cleanup runs only after actual platform termination. An implementation that never supplies a termination acknowledgement deliberately leaves the source on disk; no timed deletion or cancellation-based guess is permitted.
