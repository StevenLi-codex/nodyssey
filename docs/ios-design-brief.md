# iOS forum UI refinement

## Direction

Primary surface: **Explore** — a forum topic list, not a social feed or a marketing page.
Keep the Android app's information density and direct-entry profile directory; translate
Material framing into system iOS controls. This supersedes the earlier Weibo direction.
The Apple design reference contributes system typography, restrained weights and neutral
surfaces only: no cinematic hero, replacement accent, gradients or content glass.

## Android source consulted

- `PostListScreen.kt`: actual `PostRow`, `LastReply`, `PinnedRow` bodies. The title has
  priority; a 20dp avatar is supporting identity, not a large author header. `lastActiveText`
  describes the last reply, not necessarily the author's post time.
- `ProfileScreen.kt`: `ProfileScreen`, `AccountCard`, `IdentityRow`, `profileSections`,
  `ProfileGridCard`, `ProfileGridTile`. The screen is a directory with identity/balance
  links and grouped content/community/settings entries, not a long settings list.
- `ProfileRepository.kt`: `createdAt` maps registration fields, including legacy date-only
  strings. It is not last-seen or an activity timestamp.

## Shipping presentation changes

- Title-first forum rows, semibold system body text, small author/avatar and board line,
  compact reply/new-reply/view counts and last-reply information. Pinned/locked/read states
  remain visible. Titles are not forcibly truncated. Thin inset horizontal separators replace
  the thick inter-post gray bands. Unlike Android's one-line pinned strip, pinned rows keep
  the requested author/board/count/time information.
- Native segmented sort control, with a menu at accessibility text categories. It still
  invokes the existing settings command/readback path. Board selection, optional page bar,
  paging, refresh, search and compose remain unchanged.
- Smaller profile identity, localized registration date, tappable existing balance
  destinations and compact content/community/settings directories. Level remains in the
  identity header, without a duplicate statistic; the Assets entry remains in community. All previously reachable
  profile destinations remain reachable; already implemented routes gain direct entries.
  No attendance success, progress or other statistics are invented.
- Existing profile loading is shown by the identity while cached content exists, instead of
  a spinner-only list row; initial loading and all failure/reload actions remain.
- Native inset-grouped list on iOS; adaptive directory columns, wrapping labels, minimum
  44pt actions, semantic system fonts, existing accent and adaptive neutral surfaces.

## Verification and boundaries

- Account behavioral suite: **35 tests passed**, including four new date tests for fractional
  and offset timestamps, date-only timezone semantics, malformed input and locale/timezone
  formatting. Initial test-first failure was a missing new helper symbol, not an executed
  failing assertion. No appearance assertions or screenshot goldens were added.
- Content behavioral suite: **27 tests passed** (includes paging restoration/settings sort).
- Real Mac CLT SwiftUI signature checks passed for Content, Account and Foundation.
  Existing macOS `onChange` deprecation warnings remain. These checks are not iOS/UIKit/
  Kotlin linking or simulator execution.
- Disposable network-free probes rendered the actual production `ContentPostList` and
  `AccountProfileScreen`, with explicit app/transport/image fixture boundaries and matching
  staged source hashes. Light/dark plus accessibility-category layouts were captured.
  The macOS accessibility profile was scrolled to its real end: viewport origin 636,
  viewport height 814, document height 1450; the final settings row is visible.
- `NativeRootView` already uses system `TabView`/`NavigationStack`. No duplicate bottom
  inset or fake glass was added. The supplied mid-scroll screenshot does not establish an
  unreachable final row. **iPhone end-of-scroll and iOS 26 glass remain device checks.**
- macOS accessibility-category rendering verifies adaptive composition, not iOS Dynamic
  Type font metrics. VoiceOver announcements and touch interaction still need device review.
- No Kotlin, authentication, profile lifecycle, app model, storage, epoch, router, API,
  or fixed build60 local-profile-path changes. No reset or legacy-data action.
- Build-only workflow version is 61; it retains the full-feature Debug iPhone archive and
  original bundle identifier. No full suite or SVG tests are requested by this delivery.

## Evidence

Scratch report: `/home/hermes/.hermes/cache/scratch/nodyssey-ios-ui-refinement.json`.
Real macOS renders: `/home/hermes/.hermes/cache/scratch/nodyssey-ios-ui-renders/`.
Disposable probe: `/home/hermes/.hermes/cache/scratch/nodyssey-ios-ui-render.py`.
The render banner explicitly says synthetic fixture and NOT iPhone.

Design audit: no gradients, hero, decorative statistics, accent rails, heavy weights,
replacement accent or content glass. Directory icons are real shortcuts grounded in the
original Android composition, not decorative feature tiles. Final packaging evidence is
recorded separately in `nodyssey-ui61-delivery.json` in scratch after archive verification.
macOS renders do not establish iPhone visual or live-login acceptance.

## Build 62: thread reading and direct comments

Primary surface: **Inspect**. Preserve the forum's title/body/floor order; do not redo the
approved feed or profile directory. Reference:
https://github.com/emilkowalski/skills/blob/main/skills/apple-design/SKILL.md
— design principles only, not a SwiftUI dependency or executable instructions.

- Body semantic fonts remain unchanged. Signatures now carry an inherited rendering role:
  footnote text and inline code, restrained headings, secondary system foreground, and a
  labeled neutral inset. Paragraphs, links, lists, tables, quotes, folds, tabs and source-code
  attributed runs consume that role rather than overriding an ineffective outer font.
- The fixed bottom `写评论…` / `寫評論…` / `Write a comment…` control opens the existing
  `PostComposer` reply mode with exact Int64 post identity and no quote. It never submits.
  Guests enter existing sign-in; unloaded threads disable the entry. Floor replies retain
  quote context and now show icon plus text. The duplicate toolbar reply icon is removed.
- `ThreadSnapshot` exports no reply-lock/capability field. Do not infer permission from a
  stale feed summary's lock icon. Existing editor/backend checks remain authoritative.
- Color changes are thread-only: cool-neutral light/dark canvas gaps, solid readable body
  surfaces, subtly shaded signature inset, system tinted bordered comment control with
  primary foreground. Existing accent/theme settings, homepage and profile are untouched.
- A single `safeAreaInset` reserves the comment entry's actual height. Root system TabView,
  NavigationStack and editor keyboard handling remain unchanged; no tab-height constants,
  keyboard avoidance overrides, custom motion, transparent content or new dependencies.
- Verification: Content suite 30 tests reported passed (one existing repository-replay test
  skipped without its optional fixture); Editor suite 38 passed. Three new reply tests cover
  guest routing, loaded state/direct payload, and floor quotation including overflow IDs.
  Test-first RED was a missing new helper, not an executed failing behavioral assertion.
- Real Mac CLT SwiftUI typecheck passed. Disposable production-render probes verify smaller
  signature layouts through nine rich-node paths, plus light/dark thread captures at 320/390pt
  and scroll-end visibility above the entry. Appearance assertions remain scratch-only.
  macOS ignores iOS Dynamic Type font metrics: accessibility-category captures were identical
  to normal, so they are not large-text acceptance. iPhone TabView/keyboard/VoiceOver and
  live posting are untested. Existing macOS onChange deprecation warnings remain.
- No Kotlin, auth, storage, app-model, routing contract, editor lifecycle, spending policy,
  read-position or floor-image export source changes. Full SVG suite remains unrun.
  Archive workflow changes only build number to 62, retaining unsigned Debug iPhone target.

Build62 evidence: `nodyssey-thread62-delivery.json`, `nodyssey-thread62-*-tests.log`,
`nodyssey-thread62-typecheck.log`, and `nodyssey-thread62-renders/` in Hermes scratch.
