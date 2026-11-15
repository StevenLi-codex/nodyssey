# Native Pro Max integration: author quick card (first slice)

This is an independently implemented SwiftUI feature inspired by the author-card
interaction in **NodeSeek Pro Max**, not an embedded plugin/userscript engine.
It does not claim that all Pro Max functionality has been integrated.

## Provenance and license

- Original author: **用蚊香买榄菊**.
- Audited version: **1.2.6**, downloaded from
  <https://update.greasyfork.org/scripts/605053/NodeSeek%20Pro%20Max.user.js>.
- Discovery/source page:
  <https://greasyfork.org/zh-TW/scripts/605053-nodeseek-pro-max/code>.
- SHA-256 of the audited source:
  `a58b0fbcfbffb69fd4d234669951fb1b3ebe5c7e4f8a16e58bb0ac4252a0929d`.
- Its metadata declares **GPL-3.0** and credits the earlier **NodeSeek Pro+**:
  <https://greasyfork.org/scripts/602733>.
- This repository's root `LICENSE` is GNU GPL version 3. Preserve author/license
  notices and provide the corresponding source with distributions, including
  these native modifications. The script metadata is not an “or later” grant.
- No JS/CSS, GM compatibility code, CDN dependency, or script update loader was
  copied into the app. Feature attribution is also visible in the native sheet.

## Presentation contract

```swift
AccountAuthorQuickCard(uid: authorUID)
    .environmentObject(app)
```

The caller presents it **only after an explicit author gesture**, as a SwiftUI
sheet. It supplies a validated positive `Int64` UID from the existing author DTO,
not a parsed display name, guessed identity, or `Double`. Do not create a card
for every feed row: constructing/mounting its view starts its bounded read.
The card owns its `NavigationStack`, close control, scroll content and iOS 16
medium/large detents. Do not wrap it in another navigation stack.

For a parent that must wait for dismissal before opening an app destination:

```swift
AccountAuthorQuickCard(uid: authorUID, onNavigate: { destination in
    // Stage destination plus app.generation in the parent's transient state.
    // In the presenting sheet's onDismiss, require the same generation, then:
    // .signIn -> app.showSignIn()
    // .route(route, arguments) -> app.open(route, arguments)
})
```

The card requests dismissal before handing off. The default handoff uses those
same existing app methods synchronously. A custom handoff must retain the
`.signIn` guard and reject a pending route if the session changes before delivery.
**Integrated in build64 sources:** feed and thread author gestures present this
card. Both callers defer route handoff until dismissal and discard pending
navigation on identity change. This is source integration, not device acceptance.

## Data and lifecycle contract

- `AccountAuthorQuickCardState` uses `app.transport` and the production
  `NativeRequestState` (the same cancellation/generation primitive used by
  `NativeStore`). It does not create another transport, repository, database,
  native persistent cache, browser, or account graph.
- First request: **`profile.user`, `{"uid": <Int64>}`**.
  `NativeAccount.kt` delegates to `graph.profileRepository.profile(uid)`;
  `NativeAccountMapping.kt` exports the actual `UserProfile` DTO.
- Profile response UID must match the requested UID before any display,
  navigation or notes request. Missing/wrong UID is an error, not a usable card.
- Then **`notes.get`, `{}`**, through the existing `userNoteStore` route.
  The bridge currently returns the note list; only the exact UID's note is
  retained in transient presentation state, and the full response is cleared.
  Notes failure is distinct from “no note saved” and does not discard the
  successfully loaded profile. No `notes.set` is dispatched.
- Available avatar/name/rank/registration date/bio/topic and comment counts come
  only from that DTO. Missing data is “Not provided”, never fabricated zero.
  Invalid/absent dates use that same placeholder; `AccountProfileDate` retains
  the app's established registration-date semantics. Counts are not scores.
- Profile and note text are native `Text`, not executable HTML or links.
  Avatars use the app's existing `NativeRemoteImage` pipeline, not URLSession.
- Opening and explicit retry perform these reads only. There is no timer,
  observation, polling, feed-wide prefetch or session-change automatic reload.
- UID replacement, session generation change, task cancellation and dismissal
  fence late callbacks. Reading the snapshot checks generation immediately,
  even before SwiftUI's `onChange` cancellation runs. A session change clears
  state; the reader must explicitly retry or reopen.
- “View full profile” opens **`UserSpace`** with `uid` only.
  “Message” requires the real DTO name and current signed-in state; signed-out
  readers go to existing sign-in, otherwise **`MessageThread`** receives exact
  `uid` and `userName`. Opening the route sends no message.
- No follow/block writes, attendance, uploads, AI requests, API keys, telemetry,
  safety scores, certification badges or UID-derived trust claims are added.
  The existing backend remains responsible for admission/session policy.

## Verification and remaining gates

The checked-in `NativeAccountUITests/run-mac-tests.py` discovers the new
`*State.swift` and test file without runner changes. It executed **43 tests** on
Mac, including **8 focused author-card cases**: exact Int64 request arguments and
notes filtering; cancellation; UID replacement/old cleanup; session change during
notes; failure/read-only retry; mismatched/invalid UID; absent name; and authenticated,
identity-bound navigation. The test transport is controlled and never contacts a
live forum. Test-first evidence includes the missing new-state/API compile gates
and a genuine cancellation/loading behavioral failure before its fix.

`--typecheck-ui` passed the complete Account/Rendering signature check using the
existing CLT adapters. Its macOS deprecation warnings include the iOS-16-compatible
single-argument `onChange`; this is not an iOS/UIKit/Kotlin link result.

A disposable Mac probe also compiled the exact production card/state/date sources
and rendered `AccountAuthorQuickCardContent` with network-free synthetic fixtures
in populated/missing and light/dark variants. Exact staged hashes were verified;
real SwiftUI PNGs were produced. This verifies the content composition, **not**
modal presentation, Dynamic Type on iPhone, actual image loading, live profile
backend behavior, route presentation or device accessibility. No appearance tests
or synthetic fixture data were added to production.

The later combined gate compiled the actual card with Content, Editing and Media.
The build64 archive is tracked separately in `native-parity-build64.md`; neither
compilation nor an IPA establishes on-device opening/dismissal, session changes,
navigation, Dynamic Type or VoiceOver acceptance.
