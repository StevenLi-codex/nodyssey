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
