# Native Content UI

## Integration

`NativeContentScreens.make(destination:)` implements **PostList, Search, Notifications and PostDetail** using the shared `NativeAppModel` / `NativeStore` contract. All production files are in `iosapp/Nodyssey/Native/Content/`; none embeds Compose or substitutes a Web screen for content. Cross-domain destinations use `app.open` (validated links use `app.openLink`). Add every Content Swift source to the app target **once**, and compile `Content/Resources/Content.xcstrings` as the **Content** string table. It contains English, Simplified Chinese and Traditional Chinese translations; controls explicitly select that table. Do not add the test package or signature fixtures to the app target.

### Implemented surfaces

- **PostList:** Room/Paging `feed` observation; board selection, sort, page navigation, pull refresh, independent refresh/append/prepend failures and retry; stable post IDs and read/new-reply metadata. Board order/disabled edits use `settings.homeBoards` and readback. Recent boards use the supplement observation/record API, and are filtered against the current catalogue. Search/new-post entry points are real routes. Per-board **and sort** transient restoration stores the actual loaded row page, not the presenter's requested starting page.
- **Search:** initial query, post/user/local targets, board/sort filters, actual paging search, user-space navigation, retry/empty/error states. Search defaults to `POST_TIME` as the shared search contract specifies. History observation/record/exact-entry removal/target-specific clear use the supplement APIs, preserving query, target, category and sort. It is not falsely labelled site-isolated. Clearing the input returns to history.
- **Notifications:** independent interaction, conversation and count observations with independent error recovery. Interactions retain the repository's merged identity, date groups, unread and reply/mention indicators. Opening an interaction sends its **entire sources array**, including null `viewedId`; no invented IDs or client-side merge. “All read” explicitly acknowledges REPLIES and MENTIONS separately, or invokes `messages.readAll` for the message tab. Conversation navigation preserves UID, including system conversations; new-conversation member search opens MessageThread. Deep-link `group:messages` selects the messages tab. Refresh is explicit invalidation-driven loading, not simulated realtime polling.
- **PostDetail:** optional first-frame preview, Room observation, explicit load/adjacent-page extension, first-new-reply marker, page/floor jump, saved-position resume (clamped after thread shrink), debounced shared position writes, blocked-floor reveal, badges/edit markers, author navigation, collection, real tracking toggle and tracking library, native link sharing. Opening reads `thread.status` **before** marking read; fresh cache is reused only if it contains the requested page and no unread baseline forces a load. A null thread clears the rendered content. Comment IDs/floors anchor normal rows; a display-only ordinal is used only when the DTO contains neither, never as an API identity.
- **Actions:** reply carries post ID, quoted floor, author and a plain contextual excerpt. This excerpt is **not** used to reconstruct editing Markdown: edit routes carry the original comment ID/opening-post/page target for the editor's `editor.edit.load`. Free upvote, chicken leg and dislike use the exact Kotlin action names. Signed-out actions route to sign-in. Chicken-leg/dislike confirmations disclose irreversible spending; free allowance is fetched rather than assumed. Authoritative repository/Room state supplies reaction counts and spent flags. Failed reaction work disables repeat controls until an explicit network-only reconciliation covers the affected identity. The shared reconciliation seam is currently an open integration gate; ordinary thread reloads never unlock it.
- **Rich content:** canonical `NativeRichNode` decoding through the existing renderer for body and signatures; malformed rich data shows an error, not an empty post. Top-level polls render live native controls; nested poll markers open the same native poll in a sheet. Image context navigation recursively gathers nested image URLs and uses ImageViewer's actual `{urls,index}` contract. NativeRemoteImage retains ownership of ordinary tap/retry/metered-data consent. Receive-code navigation preserves all five fields (`memberId`, `refId`, `amount`, `description`, `onetime`) for the Library domain's authenticated review/payment confirmation.
- **Polls:** `vote.get`, single/multiple selection, server-selected state, nullable counts, public voter pagination without an invented total, owner detection from `profile.self`, submit/lock/unlock/delete confirmations. Writes do not optimistically invent totals; successful mutations are re-read. Failed/indeterminate mutations cannot be immediately resubmitted; refresh must succeed first. Creation is the editor domain's responsibility. There is no unsupported server-push claim.
- **Reports:** `reports.parse` receives original code plus canonical UTF-16 ANSI spans. Shared NodeQuality/YABS output renders native fields, tone-labelled badges, horizontally scrolling tables and notes, metadata and footnotes. Null parse result retains the real source and states it is not a recognized report. Source remains available via NativeCodeBlock. Compare preserves report, post ID, thread title and floor in `reports.add`, reads the basket back and navigates to ReportCompare. No parallel Swift report parser or fabricated adaptation.

## Lifetime and correctness

Each observer is awaited by a SwiftUI `.task(id:)`; session generation/retry cancels the previous operation. Each live pager gets a fresh UUID. The presenter snapshot replaces the window instead of being appended to a native array. `paging.access` uses `placeholdersBefore + localIndex`; rows use exact `Int64` IDs, including values above 2^53. Placeholder counts are validated but are never rendered as fabricated posts. Mutation tasks are single-flight in `ContentCommand`, cancel on screen disappearance and do not automatically retry. Foundation owns stale-response/session invalidation; Content never creates a second repository/cache.

Incoming floor labels are parsed in Kotlin's **Int32** range while entity IDs remain Int64. `#0` is page one, `#127` is page thirteen; an invalid/overflow floor falls back to the explicitly named page. Floor matching uses the parsed number so a native deep link carrying `127` still finds the server's `#127` label. Position writes use the server-provided row/page context.

Requests used only for readback do **not** call `load` on an active observation store: that would cancel the observer. Site URLs are obtained from `site.get` and its **current**, not selected/next-launch, origin. No forum credentials, cookies, arbitrary network client or raw NSError details are persisted or logged.

## Executed verification

Run from repository root:

```sh
python3 iosapp/NativeContentUITests/run-mac-tests.py
python3 iosapp/NativeContentUITests/run-mac-tests.py --typecheck-ui
```

The approved nested SSH runner stages only source/test files under `/Users/steven/.cache/hermes-build/nodyssey-content`. It copies the **real production ContentState.swift and NativeCore sources**, not a second implementation, into a temporary Swift package.

- **8 Swift Testing tests passed**, Apple Swift **6.4.2**, arm64 macOS. Tests cover global paging access/exact identities/null clearing; Kotlin floor bounds and resume clamping; fresh-cache/unread/named-page precedence; board/sort/page restoration; login/spending/spent reaction decisions; merged nullable notification sources; single/multiple poll selection and server reconciliation; nested plain quote context.
- An actual runtime RED exposed `#2147483648` incorrectly becoming page `214748365` instead of falling back to the named page. The Int32 boundary fix made it GREEN. Other new API tests first failed because the new API/source did not yet exist; those are compilation/prerequisite REDs, **not claimed as executed assertion failures**.
- **macOS SwiftUI typecheck passed** using the real Content and Rendering sources, Swift 6, MacOSX26.5 SDK and macOS 13 deployment target. The test-only `Typecheck/Contracts.swift` supplies signature fixtures for Foundation/platform interfaces, never runnable fake repositories. This proves SwiftUI call/type consistency against the frozen signatures, **not** UIKit or NodysseyShell linkage.
- CLT SwiftPM emitted missing Xcode-style framework/search-path linker warnings while completing the tests successfully. One SSH banner timeout was retried successfully; it was not hidden as a pass.
- No live posts, votes, reactions, messages, payments, uploads or account mutations were performed. No commit or push.

## Remaining acceptance boundaries

This is source/runtime-state implementation, not a blanket baseline-parity certification. Parent must still add target/resource membership and run the actual Kotlin/Native framework + Xcode iOS build, then simulator/device checks for navigation, observation release, window restoration while physically scrolling, keyboard/sheets, Dynamic Type/VoiceOver and signed-out/account-switch transitions. The current test directory is **Swift behavioral tests**, not a claimed XCUITest execution.

Native link sharing is implemented; the old Compose floor-as-image share-card rendering is not reproduced here. Primary image taps still use NativeRemoteImage's existing single-image presentation; the recursively collected multi-image gallery is reached through its explicit image context action. Renderer-owned media selection/layout limitations remain those documented in `swiftui-richtext.md`. Editor publish-success navigation/new-floor handoff, library payment constraints and report basket comparison need parent cross-domain UI verification with the actual factories. Live backend failures and actual irreversible writes are deliberately not acceptance-tested against an account.

## Review corrections: CL-01, CL-03 and G-02

### CL-01-R1/R2 follow-up status

The Swift command no longer accepts any `thread.load` snapshot as reconciliation. `ReactionReconciliationTests` reproduced both replacement and extension unlocks before that fix (`reaction-r1r2-red.log`, four failed assertions), then passed (`reaction-r1r2-green1.log`). Explicit receipts require post/page/comment-or-opening identity, session generation, uncancelled completion, and the mutation token; late reads after a later uncertain mutation remain blocked. The page/opening identity is frozen in the real confirmation/send path.

`reaction-repository-regression.py --baseline-only` executes the current production PostRepository source, real Room/SQLite and exact native thread dispatch/mapping. It produced actual offline-fallback, merged-page and replacement-page snapshots. `ReactionRepositoryReplayTests` replayed those results through the actual Swift command for both reply and retained-opening cases, all blocked (`reaction-real-baseline-green.log`). This is separate-process contract replay, not Apple interop. That run reports 27 discovered tests, with 26 passing test functions and the dedicated network-coverage replay explicitly skipped because no backend receipt exists yet. Scripted network-receipt tests are not proof that the backend seam exists.

**Open blocker:** shared `PostRepository.reconcileThreadReactions` and `ThreadReactionRead` remain absent. The full repository regression intentionally fails for the unsupported operation (`reaction-repository-contract-red.log`); no offline result has been relabelled network evidence. The native bridge patch is staged, not applied, until this seam is supplied under the existing session boundary. See `swiftui-reaction-reconciliation.md`. Explicit Reload currently fails closed; CL-01 is not accepted as complete. The SwiftUI signature typecheck passed (`reaction-typecheck.log`), not an iOS build.

To finish after the shared seam is available, apply the staged bridge patch, run `python3 iosapp/NativeContentUITests/reaction-repository-regression.py` without `--baseline-only`, then pass its printed `CONTENT_REPOSITORY_REPLAY` path to `run-mac-tests.py`. The complete receipt replay must run with no skips. Kotlin/Native, full session-bound integration, simulator/device and no-live-spending acceptance remain separate gates.

### Changes

- **CL-01:** extracted the existing command/reaction/load paths into production `ContentCommand.swift`, compiled by both the app and the behavioral package. `ContentThreadCommand` now owns a separate published `reactionsBlocked` latch. Failed or interrupted reaction work sets it; clearing the general error, successful tracking/bookmarking, and cached `thread.config` reads cannot clear it. Only a completed **network-only `thread.reconcileReactions`** receipt covering the affected post/page/comment identity (or opening-body identity), in the same session generation and reconciliation token, can clear it. Ordinary `thread.load` is **not authoritative reaction evidence**: its normal offline fallback and partial-window merge behavior remain supported and never unlock spending. The explicit Reload action targets the uncertain comment's page, or page one for the opening body. Coverage is produced by the shared repository from the new network response, never inferred from the merged snapshot or a TTL. Missing account reaction config, null/wrong-post/wrong-page/wrong-comment receipts, failure, cancellation and stale-session reads stay blocked. The send handler itself refuses retries, not just the button. Reply/edit are no longer disabled by unrelated command errors, and a localized Reload action remains available after an unrelated action clears the error message.
- **CL-03:** the actual `onImage` callback is now `ContentImageGallery.onImage`. Nested ordinary images retain ordering/deduplication. If the clicked URL is missing from that list (notably a sticker), navigation opens exactly `[clickedURL]` at index zero, never index zero of an unrelated gallery.
- **G-02 / feed:** the home feed reads `app.settings.feedSort` rather than maintaining a second local selected sort. Its picker sends `settings.set {key:"feedSort",value:"LAST_REPLY"|"POST_TIME"}`, then verifies `settings.get`; the existing shared settings observer remains the only publisher. Failed writes/readback mismatches surface errors, with no invented successful local preference. `homePageBar=false` hides only the home page-entry control; paging remains enabled. Per-board/sort restoration remains separate. Pending command work checks cancellation/session generation before dispatch, and preference writes check again before readback.
- **G-02 / nested reports:** `ContentRichBody` no longer special-cases only top-level code. It supplies `codeContent` to `NativeRichTextView`, so code in quotes, folds, both tabs and list items uses `ContentReportView` with inherited image/link/quote/poll/Stardust/code callbacks. Content-derived report IDs use sorted JSON encoding, so settings changes do not recreate the report owner. Explicit Source/Adapted/Compare actions remain per-report overrides; ordinary code remains source-only when `reports.parse` returns null.

The production composition regression mounts the actual `ContentRichBody`/`NativeRichTextView` tree in `NSHostingView`, exercises nested quote/fold/tab/list code, verifies original ANSI spans/columns and inherited callbacks, flips live report preferences, and checks explicit report actions. It uses only synthetic `reports.parse`/platform boundaries and does not assert source strings or perform network/image work.

Exact Kotlin contracts inspected: `model/FeedSort.kt`, `data/settings/SettingsRepository.kt` (`UserSettings` defaults and `ReportFormat`), iOS `NativeSettings.kt` / `NativeSettingsMapping.kt`, and Compose `PostRichContent.kt`. No new enum spellings, mutation API or Swift persistent preference store was introduced.

### Behavioral TDD and executed evidence

Before fixing existing behavior, small extractions preserved the old production command gate, gallery callback and preference defaults so tests could exercise the same code used by the views. Tests are executable Swift Testing assertions, not source-string checks. The request boundary is synthetic and recorded; there is no real account/network mutation and no claim that a scripted boundary tests Kotlin DataStore persistence.

`python3 iosapp/NativeContentUITests/run-mac-tests.py` completed on the approved Mac with Apple Swift **6.4.2**: **19 tests passed**, including the original eight tests. Regression evidence under `/home/hermes/.hermes/cache/scratch/`:

| Evidence | Observed RED before fix | GREEN |
| --- | --- | --- |
| `content-cl01-red.log` | Three assertions: successful tracking, bookmark and local config each incorrectly unblocked the failed reaction | `content-cl01-green.log` |
| `content-cl01-race-red.log` | Older in-flight refresh incorrectly cleared a later indeterminate reaction | `content-cl01-race-green.log` |
| `content-cl03-red.log` | Clicking stickerS opened imageA; both selected URL and gallery assertion failed | `content-cl03-green-retry.log` |
| `content-g02-feed-red.log` | Stored POST_TIME became LAST_REPLY and disabled home page bar remained visible | `content-g02-feed-green.log` |
| `content-g02-report-red.log` | SOURCE preference was ignored with no per-report override | `content-g02-report-green.log` |
| `content-g02-guards-red.log` | Readback mismatch reported success; pre-dispatch cancellation/session change still dispatched writes | `content-final-tests-retry.log` |

The new sort mutation API's first test run (`content-g02-sort-api-red.log`) was a **compile/API-absence failure**, with Swift's “failed to produce diagnostic” error for the missing method, not an executed assertion failure. It is not counted as behavioral RED. The later readback/lifecycle assertions above did execute and fail before their fixes.

`python3 iosapp/NativeContentUITests/run-mac-tests.py --typecheck-ui` passed after correcting a non-Hashable JSONValue view ID to encoded code data (`content-final-typecheck.log`, exit 0). This compiles actual Content + Rendering against signature fixtures with Swift 6 / MacOSX26.5 SDK, **not** UIKit/Kotlin linking. CLT test links still warn about absent Xcode-style framework search directories. Two test attempts hit SSH banner timeouts; both were retried, and only successful retry logs are counted. Scoped `git diff --check -- iosapp/Nodyssey/Native/Content iosapp/NativeContentUITests docs/swiftui-content-ui.md` passed (exit 0).

### Recursive report integration verification

Run the current full Content suite with a complete repository-generated replay (the replay path is printed by `reaction-repository-regression.py`):

```sh
CONTENT_REPOSITORY_REPLAY=/path/to/replay.json \
CONTENT_MAC_STAGE=/Users/steven/.cache/hermes-build/nodyssey-content-owned-stage \
python3 iosapp/NativeContentUITests/run-mac-tests.py --composition
CONTENT_MAC_STAGE=/Users/steven/.cache/hermes-build/nodyssey-content-owned-signatures \
python3 iosapp/NativeContentUITests/run-mac-tests.py --typecheck-ui
```

The final nested-integration run passed **29 test functions / 49 expanded cases, zero skips**, including all reaction tests, using Apple Swift 6.4.2 and the independently generated `reaction-repository-5t65_ksx/replay.json`. Logs: `content-nested-integration-final.log`, `content-nested-integration-final-typecheck.log` under the Hermes scratch directory. The checked-in signature runner now stages and typechecks the **actual Native/Sharing sources**, not replacement Sharing signatures; the standard command also passed (`content-standard-typecheck-final.log`). `CONTENT_REPOSITORY_REPLAY` and `CONTENT_MAC_STAGE` remain supported.

Behavioral RED (`content-nested-integration-red4.log`) observed only the root report reaching `reports.parse`; the nested list parse was absent. After wiring, a second runtime assertion exposed 21 parses instead of 7 across two preference changes (`content-nested-integration-green.log`): unordered JSON IDs replaced report owners. Sorting encoded keys fixed that without weakening the identity assertion. Earlier build attempts hit a missing Sharing staging dependency and a test-only Swift ViewBuilder trap declaration; these are setup failures, not behavioral REDs.

Composition compiles real Content/Sharing/Rendering sources, except `NativeCodeBlock` is a terminal source-leaf lifecycle probe. Foundation request/store and platform image boundaries are explicitly test-only; synthetic parsed report data tests policy, not Kotlin recognition. The explicit Source/Adapted/Compare cases invoke callbacks inherited from nested code and mount the real report sheets. AppKit sheets need a nonzero content size to materialize lazy List rows; offscreen test windows are cleaned up. Existing CLT search-path and macOS `onChange` deprecation warnings remain. No live requests or account writes were made; no commit/push.

### Acceptance still separate

- **G-01 floor-as-image sharing remains pending.** These fixes do not imply full Content acceptance.
- Nested automatic report adaptation is now composition-tested through the Content owner. Full iOS/Kotlin report parsing, tab/fold interaction, picker taps and real navigation remain separate device gates.
- Parent owns the full iOS CI/compiler integration and simulator/device acceptance. Mac behavioral tests and SwiftUI signature checks are distinct gates. Actual app settings-observer/picker interaction, navigation/layout/accessibility, and Kotlin persistence must still be checked on that path.
- New production files are `ContentCommand.swift`, `ContentImageGallery.swift`, `ContentPreferences.swift`; new tests are `ContentCommandTests.swift`, `ContentImageGalleryTests.swift`, `ContentPreferencesTests.swift`. `run-tests.sh` stages those real production files. No Rendering/Foundation/Kotlin source, Xcode project, other domain, commit or push was modified by this work.
