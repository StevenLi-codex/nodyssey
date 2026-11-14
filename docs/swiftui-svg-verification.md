# WebKit SVG simulator failure: evidence and next gate

## Verified baseline, not a root-cause claim

- GitHub run `43555983111`, revision `33d782448dde7baf600006639e047e48642196f2`, compiled the iOS production and test sources, linked the native executable and ran **39 tests: 38 passed, 1 failed, 0 skipped**.
- `TEST-iosSimulatorArm64Test.io.github.nodyssey.ios.WebKitSvgRasterizerTest.xml` records the failure at the original test line 63, `assertNotNull(render.await())`, with a testcase duration of **7.563 seconds**. The render completed; it returned null. PNG decoding, dimensions, alpha and orientation assertions were not reached.
- The XML's `system-out` and `system-err` are empty. The Gradle execution log contains no navigation/PDF/encoder error identifying the null-producing stage.
- `SvgRasterPipeline` at that revision uses **8,000 ms**, not 7,500 ms. Its timeout converts cancellation to null; navigation failure, a null PDF callback, and native PDF/bitmap/ImageIO failures also return null. Duration alone does not identify which path occurred, and the recorded duration is shorter than the configured deadline.
- The stack enters `kotlin.native.internal.test.TestRunner` / `Konan_start`. This is a standalone simulator executable, not app-hosted XCTest. The test already pumps Main's run loop while starting work on `Dispatchers.Default`; adding that pump again is not a fix.
- Commit `29c445d` introduced both the worker pipeline and this integration test. There is no earlier passing version of this test in the inspected history, so the artifacts do not establish that moving rasterization off Main caused the failure.

Baseline artifacts inspected under:
`/home/hermes/.hermes/cache/scratch/nodyssey-ci-43555983111/`.
The XML is in `artifacts/nodyssey/nodyssey/iosapp/build/test-results/iosSimulatorArm64Test/`;
the execution log is `native/11_Execute Kotlin simulator behavior tests.txt`.

## Diagnostic-only change

`WebKitSvgRasterizer.rasterize` accepts an optional diagnostic sink, enabled only by the existing integration test. It reports fixed stage identifiers, monotonic elapsed milliseconds, `NSThread.isMainThread`, and an allowlisted NSError domain plus numeric code. Unknown domains become `other`. It never exports markup, URLs, `localizedDescription`, `userInfo`, cookies or credentials. The test sink only prints `[svg-raster]` lines; it must not block or throw.

The patch observes existing branches, without changing results, deadlines or retry policy:

- `navigation.failed` / `navigation.provisional_failed`: error domain and code from the actual delegate callback.
- `navigation.process_terminated`: WebKit reported its content process exited. Observation only; the original timeout/fallback remains in force.
- `pdf.callback.null` / `pdf.callback.data`: distinguish PDF capture failure from later worker failure, preserving the actual error domain/code even if data is also returned.
- `pdf.*`, `bitmap.*`, `png.*`: identify the native operation immediately preceding a null result. `worker.null` follows only after the existing native resource `finally` blocks unwind.
- `capture.timeout` / `worker.timeout`: an actual `TimeoutCancellationException` was observed and rethrown, not inferred from duration. Shared `withTimeoutOrNull` still owns its handling.
- `*.cancelled`: caller cancellation was observed and rethrown.
- `webview.cleaned`: emitted after `stopLoading()` and delegate removal, still on Main.

WebKit creation/load/PDF/cleanup remain on Main. Immutable PDF data alone crosses to Default; PDF copying, CoreGraphics rasterization and ImageIO encoding remain there. The shared mutex, cancellation checks, native release blocks and transparent/no-flip drawing are unchanged. The test still requires a non-null PNG, exact signature and dimensions, both asymmetric color samples and both transparent alpha samples, and completed Main cleanup. No skip, fallback acceptance or longer timeout was added.

## Parent Apple diagnostic evidence

Run `43558825991` at `d30f9e8ec7e60eafebb11d879923f04c48b468c0` compiled the diagnostic production/test sources on Apple and executed the unchanged SVG test. It failed, with this actual XML `system-out`:

```text
pipeline.enter main=false elapsedMs=0
capture.enter main=true elapsedMs=2
webview.create main=true elapsedMs=2
navigation.request main=true elapsedMs=5878
webview.cleaned main=true elapsedMs=8014
capture.timeout main=true elapsedMs=8014
pipeline.null main=false elapsedMs=8015
```

This establishes a capture-stage deadline cancellation in this run, with roughly 5.9 seconds spent before navigation was requested. No navigation-finished/failure callback or worker entry was recorded. It does not establish whether the standalone host or cold WebKit startup caused the stall. Main cleanup executed. The earlier test's shorter JUnit duration remains unsuitable for identifying the cause; the new monotonic trace supplies the evidence.

Artifacts: `/home/hermes/.hermes/cache/scratch/nodyssey-ci-43558825991/artifacts/`. An app-hosted comparison invoking the same Kotlin renderer, fixture, timeout and pixel assertions is now being added. Neither increasing the timeout nor replacing/skipping the failing test is accepted as a fix.

## Ranked hypotheses and falsifying observations

1. **Navigation / WebContent process failure in the standalone host.** Predicts a navigation failure/termination event before `navigation.finished`, and no `worker.enter`. Hosting is only a hypothesis until the callback error and a controlled app-hosted comparison support it.
2. **WebKit PDF capture failure.** Predicts `navigation.finished`, then `pdf.callback.null` with error metadata, followed by `capture.null`; no worker.
3. **CoreGraphics or ImageIO failure.** Predicts `pdf.callback.data`, Main cleanup and `worker.enter main=false`, followed by a specific native stage and `worker.null`.
4. **Deadline / dispatcher progress problem.** Predicts an observed timeout in the capture/worker stage, or `pipeline.null` during dispatcher handoff with the last completed stage visible. A trace stopping after `navigation.request` plus `capture.timeout` identifies a stalled load, but does not by itself prove app hosting is required.

## Exact next Apple CI step

Use the existing ARM macOS/full-Xcode runner. Keep the normal full-suite gate and artifact upload; do not mark this step `continue-on-error`. For the tight diagnostic run, after selecting and booting an available simulator and setting `SIMULATOR_UDID`:

```sh
./gradlew :iosapp:iosSimulatorArm64Test \
  --tests '*WebKitSvgRasterizerTest*' \
  -PiosTestDevice="$SIMULATOR_UDID" --console=plain
```

This task compiles and links the changed production and test sources as needed. A Linux `BUILD SUCCESSFUL` with native tasks `SKIPPED` is not acceptance. On failure, preserve the XML/HTML using the existing `always()` artifact upload and inspect `[svg-raster]` lines in that testcase's `system-out`; they must be present before drawing a root-cause conclusion. The original null assertion must remain red if null is returned.

The diagnostic run is useful whether red or green, but **it does not mean the bug is fixed**. Once a stage-specific fix is supported by that evidence:

1. Repeat the exact filtered test on the same simulator (force actual execution, not an up-to-date task), then on a fresh simulator. Require exactly one executed test, zero failures/errors/skips in each XML. Require `capture.enter main=true`, `webview.cleaned main=true`, `worker.enter main=false`, `worker.ok` and `pipeline.ok` in that order, plus the unchanged pixel assertions passing.
2. Run `./gradlew :iosapp:iosSimulatorArm64Test -PiosTestDevice="$SIMULATOR_UDID"` without a filter and `python3 iosapp/scripts/verify_native_results.py iosapp/build/test-results/iosSimulatorArm64Test`. Verify the SVG testcase actually executed and passed; a subset-only run is not full acceptance.
3. Run `./gradlew :shared:jvmTest --tests '*SvgRasterPipelineTest*'` to retain the dispatcher/cancellation/serialization regression gate.

Only if evidence points at the standalone WebKit host should the parent add a **supplementary app-hosted comparison**: invoke this same Kotlin rasterizer, same SVG fixture, output dimensions and pixel checks under the real app lifecycle, on the same simulator/runtime. A Swift-only replacement renderer or launch screenshot cannot test this path. Do not delete/skip/relax the failing native test to obtain green; agree on an explicit harness correction after the comparison. No Xcode project, workflow, app entry point or shared-source edits are included here.

## Parent app-hosted execution evidence

Run `43562654814` at `c264d53028697876d0eca47aa0b4b56dccf94647` compiled and ran `NativeSvgHostTests.testSameKotlinRasterizerPreservesPixels`: **1 executed, 0 failures**, 5.063 seconds. The downloaded Xcode log records `navigation.finished` at 4895 ms, PDF callback at 4925 ms, Main cleanup at 4926 ms, worker entry off Main, and `pipeline.ok` at 5000 ms. This establishes actual same-Kotlin-renderer pixel/dimension/alpha/orientation success inside the application host with the unchanged 8,000 ms policy, not merely compilation.

The same workflow's standalone native gate still failed: 48 tests executed, 1 failure in `WebKitSvgRasterizerTest`. The workflow overall failed, with the old-root navigation tests also failing. **Do not call standalone rendering fixed or the full SwiftUI application accepted.**

Simulator binding is implemented in the **root** `build.gradle.kts:21–22`, already present at `c264d53028697876d0eca47aa0b4b56dccf94647`: its subprojects block sets `KotlinNativeSimulatorTest.device` from `iosTestDevice`. Parent configuration-time inspection of the actual `iosSimulatorArm64Test.device` returned exactly the supplied sentinel UDID, confirming the property is not ignored. The prior module-only inspection was too narrow; no build fix was required. This probe validates Gradle task configuration only, not simulator execution. The hosted success is not a substitute for the standalone failing gate.

Evidence: `/home/hermes/.hermes/cache/scratch/nodyssey-ci-43562654814/native/14_Compare same Kotlin SVG renderer inside the app host.txt`, lines 960–1017, and the standalone step log. The fixed-input debug-guarded probe still exports a symbol in Release and must be isolated/removed before delivery.

## Follow-up diagnosis: initialization, load submission, and run-loop witnesses

The failure remains **unfixed**. There is not enough Apple evidence to select a safe behavioral change.
The additional patch is diagnostic only; it does not initialize `UIApplication`, prewarm WebKit,
move construction outside the deadline, attach a window, retry, or accept null.

Further inspected evidence:

- Run `43565737701` standalone XML: `navigation.request` at 6197 ms, cleanup and observed capture
  timeout at 8171 ms, no navigation completion/failure or worker stage. Its hosted comparison on the
  shared simulator requested navigation at 28 ms, finished navigation at 1528 ms, and entered the
  worker off Main at 1540 ms; the hosted test passed. This reproduces a large *pre-request* difference,
  not a worker defect.
- Run `43575181746` / `cc2f4dd`: the available standalone step log says **54 tests, 1 failure**, the SVG
  testcase. The hosted step was cancelled, so it is not another hosted pass. This downloaded log
  directory has no standalone XML or `[svg-raster]` trace: do not manufacture stage timings for it.
- Pinned Kotlin `v2.4.20` `TestRunner.kt` calls each `testCase.run()` synchronously and catches its
  exception; it does not enter `UIApplicationMain`. Pinned coroutines `1.11.0`
  `nativeDarwin/src/Dispatchers.kt` sends Main through `dispatch_async(dispatch_get_main_queue())`,
  Default through the global queue, and Main timers through CF common modes. The existing test's
  `NSRunLoop.mainRunLoop.runUntilDate` is therefore material; replacing it with blocking `runBlocking`
  while the render is pending would be a regression. Its existing `runBlocking { render.await() }`
  occurs only *after* `isCompleted`, so it does not explain the missing callback.

Source references:
[runner](https://github.com/JetBrains/kotlin/blob/v2.4.20/kotlin-native/runtime/src/main/kotlin/kotlin/native/internal/test/TestRunner.kt),
[dispatchers](https://github.com/Kotlin/kotlinx.coroutines/blob/1.11.0/kotlinx-coroutines-core/nativeDarwin/src/Dispatchers.kt).
Upstream WebKit `RunLoopCF.cpp` uses CF common-mode sources/timers; this is supporting source inspection,
**not** a claim about the exact Apple system WebKit binary shipped in the CI runtime.

The next unchanged test now distinguishes these ranked hypotheses:

1. **Synchronous initialization/service lookup consumes the capture budget.** New pairs
   `configuration.create/created`, `datastore.create/assigned`, and `webview.initialize/initialized`,
   followed by `webview.configured`, identify the expensive operation instead of labelling the entire
   six seconds “WebView construction.” No initialization moves outside the 8,000 ms deadline.
2. **Load submission or callback delivery stalls.** `navigation.request` precedes `loadHTMLString`;
   new `navigation.submitted`/`navigation.rejected` records its actual return. Provisional-start and
   commit callbacks now distinguish process/navigation progress from final page completion. A rejected
   return is observed only; the existing deadline/fallback semantics remain intact.
3. **Main/run-loop progress differs under the native harness.** After a successful load submission,
   the standalone test queues one GCD Main witness and one CF default-mode block. Both print
   `[svg-harness]` fixed stage names and main-thread flags. If both execute and navigation still times
   out, simple starvation of those mechanisms is excluded; that does not prove the WebContent process
   launched or application hosting is required. No polling coroutine, warmup, mode substitution, or
   timeout extension is introduced.
4. **Weak delegate lifetime is lost while suspended.** The existing local is last used at `awaitLoad`
   and `WKWebView.navigationDelegate` is weak. That warrants observation, not an unproved retention
   fix. At unwind, `navigation.delegate_present`/`navigation.delegate_missing` records the weak property
   *before* stopping/removing it. It neither holds a new strong reference across suspension nor forces
   GC. A missing delegate needs its own Apple regression before changing retention.

Read the witnesses alongside the unchanged `webview.cleaned`, actual cancellation stage, non-null
and all pixel assertions. Neither a witness nor a hosted pass is standalone acceptance. Keep the
existing exact filtered command above, force actual test rerun on Apple, preserve its XML, then run
hosted comparison on the same simulator. If initialization consumes the budget but both witnesses
execute, collect a process sample during that specific stage in the parent CI diagnostic run before
changing lifecycle or startup behavior. Do not log document contents, URLs or NSError descriptions.

## Release probe isolation plan (parent build ownership)

`NativeSvgVerification` remains public in `iosMain`. `Platform.isDebugBinary` prevents Release
execution, **not** exported headers/symbols or fixture presence. No host target or scheme was removed.

Prefer a separate per-target diagnostic compilation, rather than a misleading runtime guard or a
source-directory mutation in a link task:

1. Move only the facade to a diagnostic source directory. Keep renderer and production pipeline in
   ordinary Main, and keep the standalone integration test in `iosTest`.
2. Create a diagnostic compilation that includes Main's source/dependency hierarchy plus that facade;
   route only the Debug comparison framework through it. The Release framework continues to use
   ordinary Main, with no source-set dependency on the diagnostic directory. Preserve the current
   framework module name and `NativeSvgHostTests` app-host target/scheme.
3. Verify the actual configured binary-to-compilation mapping and source files for both target
   architectures. The cached **2.4.20** plugin's `NativeBinary` was inspected with `javap` and exposes
   `getCompilation`/`setCompilation`; this establishes an available configuration API, not that the
   full custom compilation/resources/framework wiring has been implemented or tested.
4. On full Xcode, clean-build the Debug hosted test and ordinary standalone test, then clean-build
   both Release frameworks/archive. Require the host test still executes and passes and inspect the
   generated Release header, symbols, and fixture presence; reject `NativeSvgVerification` leakage.
   A missing fixture string alone is not proof of symbol exclusion. Exercise mixed Debug/Release task
   invocation to detect accidental shared-source or cached-output contamination.

This needs parent agreement and Gradle/Xcode verification; **not implemented** in this scoped patch.
Do not delete the working hosted comparison to resolve the Release finding.

## Follow-up execution and blockers

- Executed the real `:shared:jvmTest --tests '*SvgRasterPipelineTest*'`: parsed XML reports **8 tests,
  0 failures/errors/skips**. All existing caller-cancellation, deadline, handoff, serialization, budget
  and cleanup tests remain unchanged. This does not exercise Apple frameworks.
- Attempted the exact standalone filtered Gradle command on Linux ARM: production/test native compile,
  linking, and simulator task were **SKIPPED**. A successful Gradle exit is not an Apple compile/test.
- The approved Mac reports `/Library/Developer/CommandLineTools`, Swift 6.4.2, and no `iphonesimulator`
  SDK. An isolated macOS Swift run-loop probe was staged under its build cache (not the app checkout).
  Its first compile exposed a Swift optional CF mode argument; that scratch source was corrected, but
  the next connection timed out and the retry awaited approval. No probe execution result, iOS pixel
  result, or root-cause proof is claimed. macOS WebKit would in any event only be a mechanism probe.
- No CI, Xcode project, production timeout, pixel/nonnull/cancellation assertions, host facade, or shared
  pipeline behavior was changed. No commit, push, workflow cancellation, or live service mutation.

## Local verification and limits

- Scoped root `:spotlessKotlinCheck` with absolute `-PspotlessIdeHook=` paths reported `IS CLEAN` for both changed Kotlin files. The IDE hook skips the outer check task; this is not a repository-wide formatting claim.
- Actual `:shared:jvmTest --tests '*SvgRasterPipelineTest*'`: **8 tests, 0 failures/errors/skips** (XML verified). This exercises unchanged shared orchestration, not UIKit/WebKit or the new Apple diagnostic interop.
- The exact native filtered task was attempted with the cached JDK 21 on Linux ARM. Gradle reported unsupported Kotlin/Native host and skipped production compilation, test compilation, linking and simulator execution. **The diagnostic patch is not Apple-compiled or simulator-verified locally, and no rendering fix is claimed.**
- Initial bare Gradle invocation lacked Java in PATH; the cached JDK was then used. Formatting is configured at the root, not `:iosapp`.
