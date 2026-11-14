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

## Local verification and limits

- Scoped root `:spotlessKotlinCheck` with absolute `-PspotlessIdeHook=` paths reported `IS CLEAN` for both changed Kotlin files. The IDE hook skips the outer check task; this is not a repository-wide formatting claim.
- Actual `:shared:jvmTest --tests '*SvgRasterPipelineTest*'`: **8 tests, 0 failures/errors/skips** (XML verified). This exercises unchanged shared orchestration, not UIKit/WebKit or the new Apple diagnostic interop.
- The exact native filtered task was attempted with the cached JDK 21 on Linux ARM. Gradle reported unsupported Kotlin/Native host and skipped production compilation, test compilation, linking and simulator execution. **The diagnostic patch is not Apple-compiled or simulator-verified locally, and no rendering fix is claimed.**
- Initial bare Gradle invocation lacked Java in PATH; the cached JDK was then used. Formatting is configured at the root, not `:iosapp`.
