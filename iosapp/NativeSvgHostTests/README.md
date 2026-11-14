# Same-renderer app-hosted SVG comparison

## Run on CI

From the repository root on the existing Apple Silicon/full-Xcode runner, using **the same disposable simulator UDID and installed runtime as the native diagnostic test**:

```sh
set -euo pipefail
: "${SIMULATOR_UDID:?Use the native diagnostic simulator}"
: "${RUNNER_TEMP:?Set CI scratch directory}"
xcodebuild test \
  -project iosapp/Nodyssey.xcodeproj \
  -scheme NativeSvgHostTests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled NO \
  -only-testing:NativeSvgHostTests/NativeSvgHostTests/testSameKotlinRasterizerPreservesPixels \
  -resultBundlePath "$RUNNER_TEMP/native-svg-host.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

The result path must not already exist. Upload the `.xcresult`, xcodebuild output and newly generated `NodysseyShell.h` even when the command fails. Do not use `continue-on-error` as acceptance, prewarm WebKit, retry until green, or reuse a stale framework. The existing host Gradle framework/resource phase stays enabled. Keep the original native run and its XML artifacts as a separate gate:

```sh
./gradlew :iosapp:iosSimulatorArm64Test \
  --tests '*WebKitSvgRasterizerTest*' \
  -PiosTestDevice="$SIMULATOR_UDID" --rerun-tasks --console=plain
```

The workflow must arrange for both independent diagnostic jobs/steps to execute and preserve both results even if the native test fails. This directory does not change the workflow or its final failure policy.

Expected discovery is **one** test in `NativeSvgHostTests`. This is not one of the three `NativeNavigationUITests`, whose target and `Nodyssey` scheme remain unchanged. The separate scheme avoids changing that suite's counts. App-hosted unit testing uses `TEST_HOST` + `BUNDLE_LOADER` pointing at `Nodyssey.app`, an actual app dependency, and the host's framework search path. It neither substitutes a standalone XCTest runner nor compiles another renderer. `Bundle.main.bundleIdentifier` must be `io.github.nodyssey`.

## Controlled variables

- Calls the actual internal Kotlin `WebKitSvgRasterizer().rasterize`, via the narrow exported `NativeSvgVerification.start(completion:)` facade.
- The SVG string is byte-for-byte identical to the existing native test: red upper-left, blue lower-left, transparent right half; intrinsic dimensions 8×8, output 16×16.
- Starts the render on Kotlin `Dispatchers.Default`; Main WebKit capture/cleanup, Default worker, mutex and cancellation handling remain inside the **unchanged production renderer/pipeline**.
- Keeps the production 8,000 ms pipeline deadline, without overrides, retry or fallback acceptance. XCTest's 15-second missing-callback watchdog and 3-second cancellation-cleanup watchdog match the outer native harness, not a longer rendering policy.
- Async XCTest expectation fulfillment releases Main to the real application lifecycle. No `runBlocking`, semaphores, manual Main run-loop pumping, or new WebKit initialization in Swift.
- Checks non-null PNG and signature; decoded dimensions 16×16; the same unflipped premultiplied-last, big-endian RGBA sample buffer; exact red/blue channels, both opaque samples and both transparent samples.
- Completion runs on Main only after the renderer's resource scopes unwind. Watchdog cancellation still allows cleanup and does not erase a recorded XCTest timeout. Kotlin cancellation is not caught/swallowed.
- `[svg-raster]` output uses the existing fixed stages, monotonic timestamps, thread flags and sanitized error codes only.

The real app starts its normal shell; no test-only root, persisted-setting injection or account action was added. Use a fresh guest simulator, not a personal/signed-in device. Natural app startup differs from a standalone executable, so a passing comparison supports a host/lifecycle effect but does not isolate its precise cause.

## Guard and release boundary

The pinned version is Kotlin **2.4.20**. Its actual `kotlin-native/runtime/src/main/kotlin/kotlin/native/Platform.kt` was inspected at the `v2.4.20` tag: `Platform.isDebugBinary` exists and requires `kotlin.experimental.ExperimentalNativeApi`. Both probe methods guard that binary property; Release `start` returns null before constructing a coroutine or WebView, and Release `cancel` is inert. The test deliberately fails rather than skipping if run against Release.

Kotlin `iosMain` has no Swift `#if DEBUG` source split in this project. **This is release-execution exclusion, not a claim that the exported facade/symbol/fixture is absent from the release binary.** A physical release-symbol exclusion would require separate verification-only framework/source-set wiring and generated-header validation; none is silently claimed here. Remove this supplementary facade/target after the host comparison and any agreed harness correction, or explicitly adopt such separate build wiring if retained long-term.

The facade accepts only a callback, plus cancellation; there is no arbitrary SVG, URL, path, script, dimensions or network input. It is not registered with NativeBridge, an app launch argument, URL scheme, server or file endpoint. It cannot perform account/forum mutations. NativeBridge/NativePlatform are untouched.

Prior actual CI `43557573059`'s `NodysseyShell.h` was inspected for callback and Foundation export conventions (`NativePlatform.image(...completion:)` exposes nullable NSData; existing classes expose named completion callbacks). The new facade's **own** generated header still requires CI compilation; the old artifact does not prove its export or linking.

## Evidence and limits

Actual native run **43558825991**, revision `d30f9e8`, reports:

```text
pipeline.enter    main=false elapsedMs=0
capture.enter     main=true  elapsedMs=2
webview.create    main=true  elapsedMs=2
navigation.request main=true elapsedMs=5878
webview.cleaned   main=true  elapsedMs=8014
capture.timeout   main=true  elapsedMs=8014
pipeline.null     main=false elapsedMs=8015
```

This proves capture timeout with substantial cold WebKit construction cost and no observed navigation finish/failure or worker entry. It does **not** prove that WebKit requires an app host, nor implicate CoreGraphics/ImageIO. No rendering fix is made. The original native assertion stays red until evidence supports a specific fix/harness correction.

Local checks executed:

- `python3 iosapp/NativeSvgHostTests/run-mac-validation.py`: real Mac `plutil` accepted the edited project; both navigation and host-test graph/scheme audits passed; Swift frontend parsing accepted the host-test source. **Syntax/structure only**, not UIKit/XCTest typechecking or iOS linking.
- Scoped `:spotlessKotlinCheck -PspotlessIdeHook=<absolute NativeSvgVerification.kt path>`: `IS CLEAN`; outer check skipped as expected for this IDE hook.
- Fixture literals compared byte-for-byte; `git diff --check` passed. Renderer, original native SVG test, pipeline and navigation scheme were not modified.
- Actual xcodebuild attempt on Linux failed because it is unavailable; the approved Mac returned `/Library/Developer/CommandLineTools` and `xcodebuild requires Xcode`. **No app-hosted RED/GREEN, Apple compilation, test discovery or pixels have been verified here.** The Swift test was written before the facade; the missing runtime is a blocked TDD gate, not a fabricated behavioral failure.

CI must require the actual test to execute and inspect the trace alongside its assertions. A green host result must show successful navigation/PDF, Main cleanup, Default worker, `worker.ok` and `pipeline.ok`. A red result is still useful diagnostic evidence; do not delete either test or increase the deadline to conceal it.
