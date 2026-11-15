# Build64: integrated native UI parity checkpoint

This build integrates the completed UI work in the normal `io.github.nodyssey`
application (Debug, version 1.2.22/build64), not a guest/preview target.
**It is not full Android parity or device acceptance.** The build-only workflow
runs a real iPhoneOS archive; its exact run/commit/manifest and downloaded IPA
verification are recorded in the delivery evidence outside the source tree.

## Included source changes

- Feed hierarchy, compact search results and notification groups; explicit feed/thread
  author gestures open the native Pro Max-inspired read-only author card. Only this
  first card feature is integrated, not the entire userscript/plugin.
- Thread floor layout/page rail/jump sheet, destination-owned inline reply sheet,
  cumulative editable quotes and reply metadata; save-before-close/departure,
  initial-load Retry intent retention, one-shot focus and page-load cancellation fixes.
- Canonical Media sticker picker consumed by Editing; sticker/gallery grids,
  explicit browser selection versus editor insertion and native reorder alternatives.
- Profile directory, account page retention/empty states/password-strength hints;
  bounded Settings input/support improvements with unsupported capabilities still explicit.
- Library bookmarks/offline management sheets, history dates, tracked counts, assets
  and attendance confirmation, ledger-first Stardust with a secondary transfer sheet.
  Unresolved transfers allow idle sheet close but retain frozen route-owned recovery,
  block repeat spending and guard permanent route departure. No live transfer was run.
- Existing viewer gains double-tap zoom and unzoomed vertical dismiss while retaining
  the existing loader, original bytes, offline/Wi-Fi/SVG policies and save/share paths.
- Behavior regressions and all three localized resource sets included. No new
  Kotlin, NativeCore, NativeAppModel, authentication/session, schema or storage-path changes.

## Evidence boundaries

The combined macOS Swift 6 signature gate passed 60 actual production Swift files
with all 118 staged inputs hash-verified. Library/Settings/UIKit were not covered
by that whole gate: the actual iPhoneOS archive is the whole-app compile/link gate.
Focused macOS tests used synthetic transports, not a real forum account: Editor 46,
Foundation 52, Account 45, Library 31, Media 14; Content reported 34 with two optional
repository-replay declarations skipped (not 34 executed passes). Settings reported
61 checks including its base checks; viewer policy reported 3 groups/11 assertions.
No full SVG/simulator suite is part of this build-only delivery; the pre-existing
standalone SVG timeout remains unresolved.

Archive success does not accept device keyboard/IME, tab return, sheet nesting and
dismiss delegates, paging/edge-back/pinch gestures, Dynamic Type, VoiceOver, live
login, installation over existing data or payment behavior. Signing is required.

## Canonical route accounting and remaining gaps

All 51 canonical routes were source-reviewed; none has iOS runtime acceptance in
this checkpoint. Final owner reports supersede the audit's four moving-owner
pending entries (thread/editor/message/viewer), but do not turn them into complete
parity. Current categories: **37 partial, 11 deferred/preserved, 3 unsupported**.
These are exclusive route categories, not a claim that 37 routes are finished.
Nested sheets/cards are not counted as additional routes. The table preserves
known gaps rather than claiming all pages are done.

| Route | Category | Remaining scope / limitation |
| --- | --- | --- |
| `PostList` | partial | Android swipe-between-board and reselect-to-top gestures not added; retained existing native behavior. Initial Android skeleton and specialized empty-board guidance not ported. Legacy hiddenHomeBoards cannot be cleared through settings.homeBoards; hidden boards remain directly selectable, but a no-op restore toggle is deliberately disabled. Android animated wrapping/drag board flow represented by native chooser + explicit reorder mode, not copied. Current account avatar in header is represented by a profile symbol; no duplicate profile fetch. |
| `Search` | partial | Android advanced-sheet draft/apply semantics and dedicated recent-board picker not implemented; disclosure preserves existing immediate scoped bindings. Server user results still intentionally link directly to UserSpace, not forced through a card. |
| `Notifications` | partial | Independent scroll-position memory/swipe pager for the two notification groups not introduced. Real iOS route handoff, VoiceOver, Dynamic Type and interaction acceptance require parent integration/device validation. |
| `Profile` | partial | Leaderboard routes to existing Assets screen rather than a dedicated inline board; no iOS update indication without capability. Attendance confirmation and actual backend execution require device test; no live account write performed. |
| `Settings` | deferred | Existing backed controls and platform limitations retained. Selected proxy/DoH/image-host/notification summaries and additional supported-control work deferred. No write-only switch added. |
| `ThemeSettings` | deferred | Existing preview/swatches and theme controls retained; richer card preview, image sampling, e-ink capability-sensitive disabling deferred. Native macOS representative rendered only. |
| `DynamicColor` | platformUnsupported | Android wallpaper extraction/auto-update unavailable; existing honest limitation and custom-color route retained. |
| `NotificationSettings` | platformUnsupported | No proven native delivery/scheduler capability; existing limitation retained, no fake enabled controls. |
| `ProxySettings` | partial | Field-specific errors, unsaved-exit guard and credential retry behavior deferred. Test still uses saved config only; no silent save. |
| `DohSettings` | partial | Field-specific URL/bootstrap errors and exit confirmation deferred. Existing actual platform capability limits retained. |
| `NetworkCheck` | platformUnsupported | Full diagnostic contract absent; existing explicit limitation retained. |
| `ImageHost` | partial | provider website/configuration affordances visual acceptance |
| `StickerManage` | partial | paste-backup import broken-count summary CDN comparisons |
| `StickerGroup` | partial | device-verified long-press drag reorder visual and VoiceOver acceptance |
| `StickerSources` | deferred | metadata hierarchy and failure-versus-empty fix outside bounded changes |
| `StickerAdd` | partial | link/upload/subscription mode layouts |
| `AboutApp` | deferred | Existing attribution and update/crash limitations retained. No APK updater or unsupported crash export added. |
| `AboutCommunity` | partial | Existing hardcoded contact/friend attribution catalogue retained; contact grouping not redesigned. |
| `Privacy` | partial | Rich document and real web fallback execution not device-tested. |
| `Changelog` | deferred | Existing release provenance preserved; rich Markdown release renderer deferred. |
| `Help` | partial | Swipe pager and onboarding persistence acceptance deferred; synthetic help render deliberately reports unsupported metadata fetch. |
| `OpenSourceLicenses` | deferred | Existing attribution retained; complete shipped native dependency inventory audit deferred. |
| `TitleKeywords` | deferred | Existing backed local keyword actions retained; field-level regex/length feedback and duplicated account presentation unification deferred. |
| `TrackedThreads` | partial | Native untrack remains confirmed swipe rather than always-visible Android trailing control. |
| `AccountSettings` | partial | Per-row storage badges deferred; signout and single-account contract intentionally unchanged. |
| `AccountProfileFields` | partial | Current avatar context, Markdown toolbar, unsaved-exit policy and revision-fenced profile/avatar readback deferred. MarkedTextEditor binds EditorBuffer/EditorFocus; safe field-level selection/handoff integration needs focused UIKit tests, so no unverified adapter or editor-file edits were introduced. |
| `AccountSecurity` | partial | Background-sensitive-field clearing and live authenticator handoff remain unverified; no policy change or real password mutation. |
| `AccountContact` | partial | Real browser cookie sharing and refresh-on-return need iOS runtime verification. |
| `AccountBlockList` | partial | Duplicate title-rule presentation remains; blocked-user name readback draft-revision issue not rewritten. |
| `AccountPreferences` | partial | Unknown fields stay unavailable; existing account-side mutation and hidden inversion unchanged. |
| `PostComposer` | partial | Existing full-screen composer/message behavior retained; shared canonical sticker picker integrated. Phrase persistence and comprehensive keyboard/IME runtime acceptance remain deferred. |
| `MessageThread` | partial | Existing full-screen composer/message behavior retained; shared canonical sticker picker integrated. Phrase persistence and comprehensive keyboard/IME runtime acceptance remain deferred. |
| `PostDetail` | partial | UIKit reply-sheet dismissal, focus/IME, picker/preview transitions, navigation return and tab restoration require device acceptance. Phrase persistence is not implemented. |
| `UserSpace` | partial | Joined-days unavailable in DTO; source-equivalent derivation deferred. Per-tab independent paging/scroll state, continuous append/end states, and swipe transitions not implemented. README native disclosure does not reproduce Android first-eight-lines collapseMarkdown preview. Notes use disclosure, not dedicated edit sheet; signed-in self request remains sequential. |
| `Follow` | partial | Independent following/follower retained state and additional metadata parity deferred. |
| `Bookmarks` | partial | Selection toolbar remains list-inline rather than Android floating bottom bar. Stale refresh banner remains existing NativeFailureView; device gestures not tested. |
| `ReadHistory` | partial | Native date/time is absolute rather than Android relative older-row wording. |
| `Assets` | partial | Real iOS ranking-to-profile navigation and modal lifetime need integration. |
| `Credit` | partial | Ledger rows still label resulting balance rather than Android aligned amount column. |
| `Stardust` | partial | Payment sheet interactions and uncertain-readback dismissal require device integration; no live spending performed. |
| `CommunityTools` | partial | External browser navigation not executed against network. |
| `MyTopics` | partial | Total/loaded count, browse-feed CTA and continuous paging/per-tab restoration deferred; existing page-local filter explanation preserved. |
| `MyComments` | partial | Total/loaded count, browse-feed CTA and continuous paging deferred. |
| `Award` | deferred | Shared home-style rich post row not adopted; existing compact LibraryPostRow and paging retained. |
| `Lucky` | deferred | Principles link and field-specific validation hints not implemented; existing shared generation and validation unchanged. |
| `Invite` | partial | Native contract provides balance/url/purchaseRequiresWeb but no cost; no invented cost or native purchase implementation. |
| `Ruling` | partial | Hide/unhide, signed currency, board catalogue labels and browser-current-page action not implemented. Complete outgoing floor normalization not added. |
| `ReportCompare` | partial | No new comparison layout or device interaction execution. |
| `ImageViewer` | partial | Double-tap zoom and unzoomed-only drag dismissal implemented; pager/edge-back/pinch arbitration and Reduce Motion require device acceptance. Additional gallery chrome and generic copy/collect/context actions deferred. |
| `SignIn` | deferred | Intentionally untouched working login/auth/session boundary. Countdown and specialized verification messaging remain audit gaps. |
| `Web` | deferred | Existing behavior preserved; no new runtime acceptance or complete parity claim. |

## Safety and explicitly unimplemented scope

Phrase persistence is **not implemented**. No generic userscript/GM runtime,
AI features, trust scoring or new Pro Max automation is shipped. Existing write
confirmation, uncertain-outcome recovery, private-boundary and provider-bound
checks must not be relaxed to obtain a green archive. No live forum write, payment,
authentication, main-branch merge, preview replacement or legacy-data migration was
performed for this integration.
