# iOS UIKit rich-selection behavior gate

This is a **separate iOS Simulator executable**, not a source added to the macOS
`NativeRenderingTests` target. It requires an Apple toolchain with iPhoneOS and
iPhoneSimulator SDKs. It never starts SSH, CI, an archive or a Release build.

## Reproduce

From the repository root, freeze inputs and emit a request for your authorized
serialized Mac wrapper:

```sh
python3 iosapp/NativeRenderingTests/Behavior/run-uikit-behavior.py \
  --prepare-request /absolute/output/request.json
```

Send that request through the approved wrapper. No fixed scratch location is
embedded in the runner or fixtures. `--device-set /absolute/diagnostic-device-set`
and `--device UDID` optionally reuse an explicitly authorized diagnostic
simulator. With no device set, execution creates an isolated device set under its
output directory; it does not modify an existing user's simulator set.

The request's frozen files can also be staged on an authorized Mac and run there:

```sh
python3 run-uikit-behavior.py --execute --inputs . --output runtime-output
```

Execution typechecks unmodified shipping rendering sources and the exact image
leaf against iPhoneOS at deployment target iOS 16, then compiles an iOS 16
Simulator-targeted application. Runtime iOS 17+ is required for the registered
UIAction cases. The generated app is ad-hoc signed and installed only in the
selected diagnostic simulator. An existing diagnostic app's result file is
removed before launch. A missing/invalid/incomplete/false result exits nonzero.
Compilation, simulator, process and result waits are bounded. The enclosing
wrapper must retain its global serialization lock and enforce its own <=900s
lease; the generated request uses 600s.

Artifacts: `source-manifest.json`, command argv/exit/log records,
`runtime-output/result.json`, and `runtime-output/run-report.json`. The JSON
report is printed as `FORMAL_UIKIT_REPORT` for a wrapper to export even on RED.
The actual collector is also callable independently:

```sh
python3 iosapp/NativeRenderingTests/Behavior/run-uikit-behavior.py --collect result.json
python3 iosapp/NativeRenderingTests/Behavior/test-runner.py
```

## Registered behavior

The original thirteen cases and two top-level image/selection checks are kept.
The mounted same-tab and A→B→A regression is promoted from the independently
executed RED/GREEN fixture without removing its assertions. Eight additional
checks cover natural TextKit attachment-provider mounting, a single selectedRange
crossing **two attachments and the text before/between/after them**, old image
closure/UIAction rejection after revoke and reactivation, current positive
controls, and actual SwiftUI representable dismantling. Registration is explicit:
22 behavior keys + 2 top-level keys = **24**, all strict booleans required true.
A known provider mounting RED deliberately keeps the complete gate nonzero.

Copy checks seed UIPasteboard with a unique sentinel. The expected plain-text
export retains all selected surrounding text; UIKit omits U+FFFC attachment
characters from its plain string. Empty revoked/disposed copies may leave the
sentinel or clear it, but may not export any old content. Bounds/window checks
are functional media-host admission checks, not appearance goldens.

## Boundaries and honest claims

- Full shipping rich-text and selection files are frozen and hashed. The
  `NativeRemoteImage` and private display **leaf** are extracted verbatim before
  instrumentation. The full remote viewer/pipeline is not compiled by this gate.
- `Boundaries.swift` provides deterministic already-loaded raster state and
  app/graph/code/viewer boundaries. It does not verify network, caches, retry,
  consent, Android, a real account, the final app or an IPA.
- Only staged copies are instrumented. The real mounted tab Button and its
  current-render notification subscriber share one unchanged action. The loaded
  image Button's onOpen is replayed programmatically.
- UITextItem has no public initializer. In a staged copy only, the iOS17 delegate
  and a URL-only fixture entry share the **unchanged shipping UIAction return
  block**. A real UIButton sends `.primaryActionTriggered` to the retained real
  UIAction before/after lifecycle transitions. This tests its revision capture,
  not system generation of UITextItem or genuine link touch acceptance.
- The natural paragraph is created and removed by SwiftUI. No manual paragraph
  update, provider construction/loadView, attachment frame assignment or
  attachment reparenting is used. Providers are read from actual TextKit layout
  fragments; their view/window/bounds and host equality are recorded. Parent
  controller ownership alone is never called visible media.
- No genuine finger selection/menu/image tap, system edge-back, iOS16 runtime,
  full-app integration or appearance acceptance is claimed.
