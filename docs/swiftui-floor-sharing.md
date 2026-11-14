# Native floor-as-image sharing (G-01)

## Delivered scope

`Native/Sharing/` implements a real local PNG card from the **loaded PostContent DTO**, decoded through the production `NativeRichNode` model. `ContentShareLink` now presents **Share link** and **Share floor as image** without changing its existing `postID/page/floor` call shape. URL sharing still uses `site.get.current`, strips inherited query/fragment/path, retains Int64 identities, and clamps page to one. The image action requires the optional `shareContext` below; a missing context produces an explicit localized explanation, never fabricated text or a background fetch.

The card preserves author, server timestamp when present, floor, thread title, complete canonical post/floor URL and Nodyssey attribution. `ImageRenderer` (iOS 16+) renders a fixed-width, opaque, explicit dark/light native SwiftUI card. The preview displays the same fitted document that was encoded. Measurement precedes rasterization; long bodies are reduced at grapheme boundaries until the whole card fits the export budget, including its footer. A visible truncation notice is included. Overlong attribution that cannot fit fails rather than silently cutting off provenance.

This is deliberately a **text-first card, not full Compose rich-card parity**. Every card and preview discloses that images, original styling and interactive content are not reproduced. Paragraphs, headings, link labels, quote references, code source, quotes, lists and table cell text survive. Images/stickers, polls and payment codes get localized omission markers. Closed folds remain closed; only the first tab is projected and additional tabs are explicitly marked omitted. Signatures are excluded, matching Compose `FloorShareCard`. No avatar or media URL is fetched or printed; no additional image-loading, cookie, WebView, upload, repository or server path exists. Unknown/malformed canonical rich nodes fail visibly.

English, Simplified Chinese and Traditional Chinese copy lives locally in `FloorShareCopy` (no resource membership needed). The entry uses the app's locale environment, including `NativeSettingsAppearance`; unknown languages retain the app's Simplified Chinese fallback. Author/body content is never translated.

## Installed floor UI hook

`ContentPostDetail.floor(_:page:opening:)` now has a `ContentShareLink` beside its real reply/edit/reaction actions. It passes that exact row's JSON DTO, page, loaded thread title, opening flag and the existing blocked-content reveal state. No first-loaded comment, feed preview or URL reconstruction is used.

Installed initializer:

```swift
ContentShareLink(
    postID: postID,
    page: page,
    floor: value.nativeString("floor") ?? (opening ? "#0" : nil),
    shareContext: FloorShareContext(
        content: value,
        threadTitle: thread.value.nativeString("title") ?? "",
        openingPost: opening,
        revealedBlocked: expanded.contains(identity)
    )
)
```

Pass the `page` already associated with this exact row, not `firstLoadedPage` for every row. The opening body uses page one and `openingPost: true`; a nullable opening-body floor becomes `#0` only under that explicit flag. Replies without floor identity fail instead of inventing one. Blocked content is refused unless the owner explicitly passes its already-revealed state. A stale/mismatching supplied floor is refused. Do not pass a feed preview, quote excerpt, signature, composer draft or some other loaded floor. The DTO does not carry post ID/page; the owning thread is responsible for that association.

The toolbar URL entry is unchanged and deliberately has no image context: its image action explains the missing context rather than guessing a visible row. The new per-floor entry removes ambiguity when several rows are visible. Reply pages come from the existing indexed `commentPages` mapping; the opening body is explicitly page one. The existing page fallback for legacy/malformed snapshots was not changed by this hook.

## Files and integration

Add all six `Native/Sharing/*.swift` files to the iOS app target with `ContentShareLink.swift`; keep existing `Rendering/RichDocument.swift` and NativeCore membership. No other domain/project/CI/Kotlin file was edited here. Files:

- `FloorShareDocument.swift`: loaded DTO/identity validation, locale selection, safe canonical URL.
- `FloorShareProjection.swift`: bounded canonical-model text projection and localized UI/disclosure copy.
- `FloorShareCard.swift`: read-only native card, actual measurement and PNG encoding.
- `FloorShareArtifact.swift`: one private local temporary-image lease.
- `FloorShareSession.swift`: preview/export ownership, cleanup, generation rejection and failures.
- `FloorSharePreview.swift`: preview and iOS completion-aware `UIActivityViewController` presentation.

There are **six** filenames in that list. `NativeSharingTests` stages the actual production sources and `RichDocument.swift`, not reimplementations. Never add its test package or Content's signature fixtures to the app target. Existing Content signature runners must now stage and include `Native/Sharing/*.swift` alongside Content when typechecking the full Content module. Parent owns that CI/project integration.

## Lifecycle and privacy

- Capture is synchronous and MainActor-owned; there is no untracked remote task to finish after account changes.
- Each preparation owns a unique `nodyssey-floor-<UUID>/Nodyssey.png` under the OS temporary directory. Directory permission is 0700, file permission 0600, excluded from backup; iOS uses complete file protection. Names contain no user/post identity.
- The preview owns the lease while the system activity reads the file. The activity completion handler removes it on completed, failed **or cancelled** activities; interactive dismissal is also handled. No success message claims an external post happened.
- Preview dismissal, entry disappearance, content/URL change, session-generation change and failed replacement clear the old artifact. `shareURL(generation:)` rejects stale generation even if the UI has not yet dismissed. A cleanup error is visible and retains the lease for retry/deinit.
- Artifact `deinit` is a final best-effort cleanup. Process termination cannot execute `deinit`; crash leftovers remain within the protected OS temp storage until OS eviction. There is no broad sweep deleting another owner/session's files.
- The normal exported PNG is retained only for the preview/activity lifetime; fixture renders are separately retained only by the opt-in test command below.

## Executed verification

From repo root on Linux using the existing approved nested SSH route, in its **own** Mac cache staging directory:

```sh
python3 iosapp/NativeSharingTests/run-mac-tests.py
python3 iosapp/NativeSharingTests/run-mac-tests.py --typecheck-entry
python3 iosapp/NativeSharingTests/run-mac-tests.py --render-artifacts
```

Parent CI can run the same durable shell runner on a Mac without SSH:

```sh
mkdir -p "$PWD/.sharing-test-scratch"
TMPDIR="$PWD/.sharing-test-scratch" sh iosapp/NativeSharingTests/run-tests.sh
```

For saved synthetic fixture PNGs add `SHARING_RENDER_OUTPUT="$PWD/.sharing-test-scratch/renders"`. The remote wrapper retrieves only PNG files into `$TMPDIR/nodyssey-sharing-renders` (override `SHARING_LOCAL_RENDER_OUTPUT`). No real forum content is used by tests.

**Observed:** Apple Swift 6.4.2, CLT MacOSX26.5 SDK, macOS 13 deployment target; **12 Swift Testing tests passed**. The runtime suite covers canonical DTO provenance/excluded signature; nested text/omission privacy; closed folds/inactive tabs; bounded grapheme/line truncation; wrong floor/blocked/malformed data; safe source URLs; actual PNG generation in all three languages × dark/light; unique private file permissions/idempotent removal; deinit and write-failure cleanup; generation invalidation; failed replacement/retry; cancellation/dismissal cleanup. PNG decoding verifies export budget, not cosmetic screenshot goldens.

The real renderer produced six fixture PNGs: English 780×2942, Simplified/Traditional Chinese 780×2884. Visual inspection of English/light and Traditional/dark found readable author/floor, intact title/URL and fully visible truncation/disclosure footer, with no clipping/overlap. These are **actual macOS SwiftUI raster outputs**, not iOS screenshots.

The `--typecheck-entry` check passed with real Sharing + ContentShareLink + RichDocument + NativeCore and existing **signature-only** Foundation declarations. The iOS activity branch is conditional and **was not typechecked or run against UIKit**. No full Xcode, Kotlin/Native app link, iOS simulator, device, iPad share-sheet, external service or posting acceptance is claimed.

Evidence under `/home/hermes/.hermes/cache/scratch/`:

- `sharing-document-red.log`: missing new document API compile failure; `sharing-document-green-retry.log`: first real test passed. Not mislabelled behavioral RED.
- `sharing-projection-red.log`: **18 executed failed assertions** for omitted nested text/markers, missing bounds and absent wrong-floor/blocked guards; `sharing-projection-green.log`: six tests passed after fixes.
- `sharing-render-red.log`, `sharing-session-red.log`: genuinely absent new APIs, compilation-only REDs; corresponding `*-green.log` contain real renderer/filesystem/session test passes.
- `sharing-final-tests.log`: final 12-test run and six render artifact retrieval.
- `sharing-entry-typecheck.log`: exit-zero entry signature check (no diagnostics).
- `nodyssey-sharing-renders/*.png`: generated fixture artifacts, not checked into the repository.

CLT emits missing Xcode-style framework/search-path linker warnings and a Testing-framework macOS-14-versus-test-target-13 warning despite passing execution. One SSH banner timeout was retried; one image-review service connection failed, then succeeded on retry. These are not iOS passes. No live post/share/message/upload, commit or push was performed.

## Floor-entry integration regression verification

The integration adds only the row initializer in `ContentThread.swift`; it does not change `ContentRichBody`, `ContentShareLink`, the six Sharing production files, Kotlin, the Xcode project or CI. At this integration check the app project still had no `FloorShare` source entries; the parent owns source membership and CI staging.

`NativeSharingTests/stage-floor-entry.py` first asserts that an image-capable action exists inside the real `floor` function, preserves the opening/reply call paths and leaves toolbar sharing independent. It stages the **verbatim production initializer and reveal-identity expression** into the test module. Four Swift tests execute that expression with the actual `ContentShareLink`, `FloorShareContext`, `NativeRichNode` decoder and `FloorShareDocument.make`. Signature-only app/store declarations trap if transport is called. This is a production-expression/document-boundary integration test, **not** a rendered UI tap or a direct invocation of the entry's private `prepareImage` method.

Regressions cover a selected later-page row rather than the first loaded reply; exact body/title/Int64 post/page/floor attribution; signature exclusion; blocked content remaining unavailable when a different row was revealed; the selected row's explicit reveal; missing reply identity despite an available comment ID; mismatching requested floor; missing title; and nullable opening-body floor becoming `#0` only under the explicit opening flag.

Executed on the approved CLT Mac with separate stages:

```sh
SHARING_MAC_STAGE=/Users/steven/.cache/hermes-build/nodyssey-floor-integration-tests python3 iosapp/NativeSharingTests/run-mac-tests.py
SHARING_MAC_STAGE=/Users/steven/.cache/hermes-build/nodyssey-floor-integration-signatures python3 iosapp/NativeSharingTests/run-mac-tests.py --typecheck-content
CONTENT_MAC_STAGE=/Users/steven/.cache/hermes-build/nodyssey-floor-integration-content python3 iosapp/NativeContentUITests/run-mac-tests.py
```

- Sharing: **16 tests passed**, including four new floor-entry integration tests and actual macOS PNG rendering tests.
- Content: runner reported 27 tests; **25 executed/passed, two repository-replay tests skipped** because no replay fixture was supplied. No replay acceptance is claimed by this run.
- Full real Content + Rendering + Sharing signature check: exit zero, no diagnostics. Foundation contracts remain signature-only; this does not validate UIKit or app linkage.
- Test-first evidence: `sharing-integration-red.log` fails with “The actual floor row has no image-capable share entry” before the production hook was added. This is a **source-wiring assertion RED**, not an executed Swift behavioral RED. Runtime integration tests then passed against the installed hook.
- Logs: `sharing-integration-green.log`, `sharing-integration-content.log`, `sharing-integration-signatures.log` in `/home/hermes/.hermes/cache/scratch/`. CLT framework/search-path and Testing minimum-macOS linker warnings remain as above. No live forum access, external share, upload, commit or push.

## Remaining acceptance

Parent must integrate the new sources into project/CI. Then build with the real iOS 16+ SDK and Kotlin framework; exercise PNG preview, iPhone/iPad activity completion/cancellation/error and dismissal, sharing while locked/backgrounded, account switching while a preview/activity is open, explicit blocked-floor reveal, long bodies/metadata and Dynamic Type/VoiceOver on the actual app. Full rich-media/interactive card parity remains intentionally unsupported and disclosed.
