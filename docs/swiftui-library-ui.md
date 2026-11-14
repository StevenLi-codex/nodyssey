# Native Library / Assets / Community UI

## Integration

`NativeLibraryScreens.make(destination:) -> AnyView?` owns exactly these routes:
`Bookmarks`, `ReadHistory`, `Assets`, `Credit`, `Stardust`, `CommunityTools`, `Award`,
`Lucky`, `Invite`, `Ruling`, `ReportCompare`, `TrackedThreads`, `AboutCommunity`.
All factories return a concrete native screen. Cross-domain navigation uses
`NativeAppModel.open` / `openLink`; no private account/content/settings view types are imported.

Add all six Swift files in `iosapp/Nodyssey/Native/Library/` to the app target. Add
`{en,zh-Hans,zh-Hant}.lproj/Library.strings` as a localized `Library.strings` resource.
These are app sources, **not** a second production Swift package. The test package stages the
actual `LibraryBehavior.swift` and `NativeCore` sources; it contains no retained implementation copy.
No App.swift, project, shared/Kotlin source, Android source, original license or authorship was changed
by this domain implementation. Original Nodyssey attribution is also visible in AboutCommunity.

`Stardust` accepts the full renderer receive marker as route arguments:
`memberId: .integer(Int64)`, `refId: .integer(Int64)`, `amount: .integer`,
`description: .string`, `onetime: .bool`. Marker fields are immutable in the payment form;
missing/malformed fields are rejected rather than defaulting an identity. A plain `Stardust`
route opens an editable transfer form, ledger and receive-code generator. Optional `recipientUid`
can prefill a plain transfer. `NativeLibraryReportView(report: JSONValue)` is available to the
content owner for an actual shared `QualityReport` result. It does not parse source or invent a report.
`ReportCompare` additionally accepts `code: .string`, optional canonical `spans: .array`, and optional
`postId`, `threadTitle`, `floor` context. It calls the newly implemented `reports.parse` supplement,
shows an explicit non-report result for JSON null, renders a native preview, and offers explicit
`reports.add` persistence of the complete canonical entry. Code and UTF-16 ANSI spans are forwarded
unchanged. This is an optional cross-domain `app.open` integration path; no content file was edited.

## Implemented behavior and bridge operations

| Routes | Native behavior / actual Kotlin operations |
|---|---|
| Bookmarks | Explicit `bookmarks.snapshot` disk read, then live snapshot observation before starting `bookmarks.refresh`; failed refresh keeps prior rows; bounded-walk truncation notice. Title/author search, all/downloaded/new-reply filters, collection/replies/pending sort. Selection survives filtering and counts hidden selected IDs. Confirmed sequential `thread.collect` removal/undo checks `bookmarks.snapshot` after each acknowledgement; wrong server echo is not treated as success. Per-ID failures remain visible outside filtered rows; completed batch progress is retained if a later item cancels. |
| Offline section | Cancellable `offline.observe`; queue/null-progress, downloading, downloaded bytes, stale reply counts and distinct failure reasons. `offline.download/cancel/estimate/settings/clear`; selected/all-pending downloads, unknown estimate rather than invented size; Wi-Fi/auto-reply/retention settings; usage. Image switch is capability-gated by `settings.capabilities.offlineImageReading`, not hardcoded availability. Clearing files is confirmed and does not uncollect. |
| ReadHistory | Cancellable `history.list`, device-local date sections and original reading position when opening. Confirmed remove obtains an opaque bridge `undoId`; restore never reconstructs a row in Swift. Failed restores retain the receipt; acknowledged restores consume it before read-back (even if refresh fails). Transient receipts expire after five minutes and are bounded to 20. Clear confirms and invalidates receipts. `settings.set(readHistoryLimit)` uses the trim-aware backend. |
| Assets / Credit | Real growth/nullable quota/level-span display, attendance status observation, fixed/random attendance confirmation and status/profile/growth/board read-back. Attendance acknowledgement and read failure are separate; both acknowledged and indeterminate writes force `profile.self {refresh:true}` before growth, without cancelling the status observation. Board paging and credit ledger paging/jump use backend page results, not fabricated totals. |
| Stardust | Cursor ledger with previous/next and explicitly current-page type filter. Recipient lookup, refreshed self profile, separate all-receipt and sender-receipt queries, own-payment and one-time-paid refusal. Tally uses all receipt rows (not distinct peers) and sums positive differences only; only sender receipts determine paid-by-me. A frozen review must precede native spending confirmation. Known shortfall is shown and blocks confirmation; null balance is unknown, not zero. The confirmed action refreshes the profile again before spending and refuses known insufficiency. One transfer request only, then ledger/forced-profile/growth refresh even after an indeterminate write error; success and refresh failure remain distinct. Session change interrupts the whole result rather than returning an old-account ledger. An unsuccessful refresh blocks another payment until a new review reads back state. Marker generation is shared `assets.receiveCode`, not publication. |
| CommunityTools | Native downstream navigation to every owned community tool. |
| Award / Ruling | Actual `community.award/ruling` page results, previous/next/page jump, retry, thread/user navigation; all documented moderation action tags, including null suspension duration meaning lifting a suspension. |
| Lucky | Validated integer input, date, prize count, starting floor and dedupe; actual shared `community.lucky` URL generation, selectable/copyable output, native share and open. No pretend server draw. |
| Invite | `community.invite` balance/read-only metadata; explicit reminder and confirmation before the genuine official purchase `Web` route with MANAGE goal. No native purchase endpoint is invented. |
| ReportCompare | Cancellable persisted basket observation, full-entry selection/removal (not title or list-index identity), maximum three selections, minimum two for compare. `reports.compare` performs alignment in Kotlin. Native columns, missing cells, field/value/badge/table/note/footnote rendering, tone accessibility labels and differences-only filter. Basket changes invalidate the old comparison. |
| TrackedThreads | `tracked.observe`, real opening and confirmed `tracked.remove` with returned persisted snapshot. |
| AboutCommunity | Real `community.memberCount`, retry/refresh, native informational content, original official community catalogue/RSS/contact/friend links, privacy route and original project attribution. |

No mock rows, credentials, local duplicate database, web-based report renderer or generic screen
web fallback exists in these production files. Swift holds only transient input, selection, read
models and opaque undo handles. The shared core remains the repository/session/storage SSOT.
A read-back on an observed resource uses `request` rather than `NativeStore.load`, because `load`
would cancel that store's existing observation.

## Executed checks

Commands from repository root:

```sh
python3 iosapp/NativeLibraryTests/run-mac-tests.py
python3 iosapp/NativeLibraryTests/run-mac-tests.py --typecheck-ui
python3 iosapp/NativeLibraryTests/repository-regression.py
```

The runner uses the existing approved nested SSH topology and stages only this domain, its test
harness and NativeCore under `/Users/steven/.cache/hermes-build/nodyssey-library`.
Latest run: **25 Swift tests passed (exit 0)**, including two trace-emitting tests whose balance assertions run in the companion JVM harness. The harness passed **four repository-backed replay scenarios**. The SwiftUI signature check also exited 0.
Toolchain: Apple Swift 6.4.2, macOS arm64, Swift Testing. The normal runner emits existing CLT
linker warnings about missing Xcode-style developer search paths; this is not a warning-free build.
Transient SSH banner timeouts were retried successfully; no fake execution result substituted for them.
All three localized string tables passed macOS `plutil -lint`; their key sets match. A static
factory inventory confirmed the exact 13 owned routes. These static checks are not UI behavioral tests.

Test-first evidence is deliberately distinguished: the initial missing source/API checks were
build/prerequisite failures, **not behavioral RED assertions**. Genuine runtime RED failures were
observed before fixing visible-selection toggling, collection-echo verification, and session-change
suppression during payment read-back. Foundation tests exercise production behavior with synthetic
request closures at the transport boundary. They never initialize a live account or send a real
post, transfer, purchase, download, attendance write or history mutation.

### CL-02 / G-03 / G-04 regression evidence

- CL-02 payment RED executed the original Swift `pay` sequence, then replayed its emitted requests
  through the **unchanged current `NativeAccount.kt` handler and mapping** with exact-source
  `NetworkProfileRepository` / `NetworkAssetsRepository`. A real profile cache was primed at a fixed
  clock inside its 60-second TTL, then fixture-server values changed. Both acknowledged and uncertain
  payment paths returned stale **100 stars / 300 chicken** instead of **92 / 305**. Attendance's
  existing status/growth sequence was extracted into the Foundation helper before the same RED
  assertion caught both attendance paths. GREEN forces profile refresh before growth in both helpers.
- The final replay also changes the fixture server *at the simulated write*, so payment's new
  preflight refresh cannot mask a missing post-write refresh. Four paths pass: acknowledged/uncertain
  payment and acknowledged/uncertain attendance. Actual profile fetch counts are three for payment
  (prime, preflight, read-back) and two for attendance (prime, read-back).
- This is a two-runtime **request replay**, not an in-process Swift-to-Kotlin or Apple ABI test.
  Swift executes the production helper; JVM recompiles the account handler/mapping and both repository
  sources against built shared/richtext jars and cached JDK 21 dependencies. The graph/context are
  compile-only adapters; DAO, HTML and JSON are in-memory I/O fixtures. Ledger rows are an empty
  fixture, attendance-status replay is skipped, and writes are *never* dispatched into Kotlin.
  The exercised production behavior is cache freshness and returned balance, not fake ordering alone.
  The runner has no live network transport. `--swift-log` may reuse a captured trace for diagnosis;
  the normal command always executes the current Swift sources first.
- G-03's extracted former own-only receipt query failed actual Swift assertions: count/received were
  **0/0** for an unpaid viewer and **1/8** for a paid viewer, versus **5/28** for all rows. Separate
  all/own reads now pass with repeated peers, refunds, zero differences and Int64 identities.
  Failed or session-invalidated partial reads return no tally, not fabricated zero/unpaid values.
- G-04 RED observed **one attempted write** despite a freshly read balance of 3 and requested amount
  of 8. GREEN performs the refreshed-profile guard *before* the write. Tests also cover nil, zero,
  exact/excess balance, exact integers above 2^53, and preflight network failure. The UI uses the same
  shortfall calculation to disable and guard opening confirmation, while retaining the frozen draft.
- Protection regressions exercise cancellation and `SESSION_CHANGED` at write, ledger/status,
  forced-profile and growth phases, and verify that failed profile read-back retains write
  acknowledgement without returning stale growth. No mutation is retried automatically.
- Harness setup initially hit missing JVM target 21 and a missing Ksoup `co.touchlab` runtime
  dependency; both were corrected. These were prerequisite failures, not behavioral RED evidence.
  No Mac Java runtime was available, hence Linux JVM replay rather than pretending Apple linkage.

The macOS SwiftUI check uses MacOSX26.5.sdk targeting macOS 13 and the explicitly labeled
`Typecheck/FoundationContract.swift` signature-only stand-in for concurrently implemented app
foundation types. The stand-in is never part of the app or executable test target. This check
validates SwiftUI syntax/API use and factory signatures, **not UIKit/Kotlin linkage or iOS execution**.

## Remaining acceptance gates / limitations

- Parent must integrate target membership/resources and compile against the final real Foundation
  implementation, exported Kotlin headers, iOS SDK, simulator and device. A passed macOS signature
  check does not prove those gates.
- End-to-end real bridge data/session invalidation, observation cancellation on navigation,
  VoiceOver/Dynamic Type/three-language UI, iOS confirmation dialogs and offline later-page/image
  reading remain simulator/device tests. Background queue maintenance is owned by existing platform
  services, not by this UI; downloads accepted into a queue are never labelled completed here.
- Content still owns its code-block callbacks. The optional `ReportCompare(code,spans,context)` path
  now calls `reports.parse` and offers persisted addition. Parent reported the supplement's 17 JVM
  tests passing; neither that report nor this UI's signature check proves Apple linkage. Content
  must pass the actual code/spans/context (or render an already-parsed report directly).
- The original receipt/ledger API cannot prove server idempotency after a connection failure.
  The UI requests read-back and renewed confirmation; it does not automatically retry spending.
- Stardust type filtering is explicitly per fetched cursor page, not a claim of server-side global
  filtered pagination. Attendance board has no total/has-next field; next is offered while the
  current response is nonempty, and an empty page is terminal rather than an invented total.
- Rich report text/footnotes are selectable native text; source ANSI and parsing remain with the
  content renderer. All table/section rows are structured native views, not dumped JSON.
- Original baseline acceptance checkboxes are **not** marked globally complete by this domain's
  source implementation or synthetic transport tests. No live financial writes were performed.
