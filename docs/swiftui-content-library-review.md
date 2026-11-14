# Content / Library independent review — open acceptance gates

Review batch `deleg_551b8104`, task 1, returned FAIL. These are source-derived causal traces, not executed iOS reproductions. The first complete SwiftUI integration checkpoint is `6a171529d43efb38bfde7fd71e932685ad1ff31b`. Fixes and independent re-review remain required; no item below is closed merely because it has been assigned.

## Consequential defects

- **CL-01 (high)** — `ContentThread.swift:191–196` gates reactions on a shared `ContentCommand.failure`, which any unrelated bookmark/tracking command clears (`ContentCommon.swift:25–28`). A response-lost spending reaction can become retryable without authoritative thread reload. Require separate reconciliation-required state; regression: failed reaction → successful bookmark/track still blocked → a proven network read covering the affected comment/page may unlock. Generic `thread.load` success is NOT sufficient: it can return offline fallback or merge an unrelated refreshed page. `thread.config` alone reads a local snapshot and is not reconciliation.
- **CL-02 (medium)** — `LibraryBehavior.swift:102–105` and attendance in `LibraryAssets.swift:61–70` read `assets.growth` after mutation without forcing profile refresh. Shared profile cache can retain the previous balance for 60 seconds. Force `profile.self {refresh:true}` before growth, preserving acknowledged-write versus failed-readback state. Require a primed-cache repository regression, not only synthetic request ordering.
- **CL-03 (medium)** — `ContentRichBody.swift:37–40,65–70` collects img/iimg but renderer also offers sticker gallery actions. A missing clicked sticker defaults to the first unrelated image. Require actual callback-selection regression and clicked-URL fallback or consistent traversal.

## Baseline parity gaps

- **G-01:** Floor-as-image sharing missing; URL share is not equivalent. Remains separately pending.
- **G-02:** Content does not consume/persist real `feedSort`, `reportFormat`, `homePageBar`. Use existing Kotlin settings; keep explicit per-report override distinct from global preference.
- **G-03:** Receive-code display fetches own receipts but omits all-payer count and positive received total. Keep all-receipt and own-receipt queries separate.
- **G-04:** Transfer confirmation lacks known-balance shortfall guard. Use authoritative nullable balance; unknown is not zero. No server-enforcement bypass has been demonstrated.

## Current actions and evidence

Content CL-01/CL-03/G-02 and Library CL-02/G-03/G-04 have been assigned to separate fix agents with behavioral regression requirements and non-overlapping file scopes. No live reaction, payment, upload, or deletion is authorized as a test.

Independent re-review `deleg_673b0665` remains **FAIL** for CL-01: **R1** offline fallback can clear the latch without a server read; **R2** another page's refresh can unlock a stale affected comment retained in the merged window. Both are source-confirmed and assigned for targeted correction with repository-backed regressions. Complete report: `/home/hermes/.hermes/cache/scratch/nodyssey-content-library-rereview.json`. No additional scoped blockers were found in CL-02/03 or implemented G-02/03/04; this does not close nested inline adaptation or full runtime acceptance.

The provider-bound image-host patch passed its original scoped independent review. Its later production test seam and concrete `NativeImageHostSelectionTest` are under a separate re-review; the parent reran the concrete class on JVM: **8 passed, zero failures/skips**. The class is no longer abstract. Apple execution of all eight named cases remains pending; compilation alone is not acceptance.

Full iOS/Kotlin linkage, factory navigation, account-generation changes during multi-request actions, physical paging restoration, and publish-success navigation remain unaccepted.
