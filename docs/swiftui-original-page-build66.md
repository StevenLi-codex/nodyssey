# SwiftUI original-page internal build 66

Version 1.2.24 (66) retains the complete native SwiftUI application and bundle ID
`io.github.nodyssey`. This is not a guest preview or a device acceptance release.
The dedicated `ios-ipa.yml` archives the normal Nodyssey target as unsigned Debug
for iPhoneOS without running simulator or broad acceptance tests.

## Integrated scope

- Original-page-inspired homepage page controls and jump sheet, viewport-derived
  visible page, bounded adjacent-page wait, terminal fallback and stale-owner fencing.
- My-page compact identity, balances, original directory ordering and guest tools.
- Native password/OTP presentation lease registered before dispatch, retained through
  retries, and cancellation drained before a new attempt or browser handoff.
  `AccountAuthSubmission.swift` belongs to the app through its synchronized Native group.
- Focused production-coordinator regression sources retained. Controlled Mac fixtures
  are not live-server authentication, UIKit lifecycle or device interaction evidence.

Full original-page parity remains incomplete: board swipes/collapsing header,
placeholder-only page traversal, attendance banner/inline leaderboard and device
scroll/keyboard/accessibility behavior are separate gates. No iNod product-page
redesign or alternate application shell is introduced.

## Storage is unchanged

This branch inherits build 64's fixed local profile:
`Application Support/io.github.nodyssey.single-local-v1/<site>/`, including
`cache/image_cache` under that profile. It is not account-scoped and does not lock
local data to an account. Sign-out/sign-in reuses the same local data; server
permission checks and request-lifetime barriers remain authoritative.

Build 65's other edition uses
`Application Support/io.github.nodyssey.upstream-enhanced-v1/` and
`Caches/io.github.nodyssey.upstream-enhanced-v1/` instead. Alternating these editions
selects different existing roots; a larger version/build number does not unify them.
Build 66 does not adopt, copy, migrate, reset or remove either root. Prior private
workspace/legacy stores stay unopened and untouched under the inherited policy;
this is not a recovery path. See `swiftui-private-workspace.md` for the unchanged
legacy public-settings allowlist and global cookie/configuration ownership.

Unsigned overlay retention requires compatible signing/team and installer behavior.
Do not uninstall, clear application data, or reset stores to install this internal
build. No real user stores, accounts, passwords or live-server writes were used for
this archive. Archive/ZIP/plist/Mach-O verification does not establish successful
installation, live login, visual parity or device acceptance. Parent review is
required before user delivery.
