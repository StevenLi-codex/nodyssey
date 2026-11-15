# Upstream iOS manual enhancements — review checkpoint

Base: `upstream/main` at `495997983257a83d47a3c01ffbbe4fbe7205db14`.
The application remains upstream's `NodysseyApp` → `nativeShellViewController` → UIKit navigation / Compose pages. This is **not** the SwiftUI rewrite and imports none of its graph, bridge, account locks or private-workspace code.

## Implemented slice

- On iOS, an explicit author tap in the original thread opens a compact read-only card. It uses the existing `ProfileRepository.profile(uid)` and retains the original full-profile navigation callback. Returned UID is validated, nullable fields remain unknown, and cancellation plus the existing session generation/fingerprint fence rejects late account results. Closing cancels the composition-owned request. No feed-wide prefetch.
- Existing `LocalUserNotes` supplies a note only after the requested profile UID is verified. Notes remain **device-local**, not server profile fields or account-isolated notes. An absent/unloaded note is not described as a successful empty notes fetch.
- The original reply and post editor toolbar gains one saved-phrases entry. Add/edit-by-name/delete is persisted under `manual_saved_phrases_v1` in the **existing SettingsRepository DataStore**. Empty by default; device-global and retained on sign-out, explicitly disclosed in the picker. Limits: 50 phrases, 60-character names, 4,000-character bodies. Whitespace/Markdown in bodies is retained. Corrupt phrase JSON fails rather than silently overwriting it with an empty collection.
- Selecting a phrase only calls the original selection-aware text insertion primitive. No publish/upload dependency or auto-send setting exists. The existing draft observer remains responsible for saving the edited draft. The original publish button is untouched.
- Upstream at this commit has no marked-text handoff helper. The new picker therefore has a **feature-local** handoff: preserve raw preedit and selection in title/body before clearing focus, hiding the keyboard and opening the dialog; close MarkdownEditorState panels. It does not change existing emoji/format/upload behavior. Actual UIKit candidate finalization still requires device verification.
- `AppContainer.manualNativeExtras` defaults false; only `IosAppContainer` opts in. Android continues to render its original author navigation and toolbars.

## Existing functionality reused, not duplicated

The original project already has full UserSpace profiles, local user-note tags/editing, reply/post Markdown editors, emoji panel state, hosted-image selection, drafts, manual publishing, history, image viewer, code copy, follow/block and manual attendance. It does **not** contain a compact author profile card or saved-phrase picker in the inspected original UI. The prior audit describing missing SwiftUI features is not evidence about this upstream tree.

No navigation shell, main page layout, reading sheet, page-jump logic, authentication flow, database schema, cookie code, WebView engine or network endpoint is changed. Feed author interactions are not expanded in this slice.

## Build 65 same-bundle overlay storage policy

Version **1.2.23 (65)** retains `io.github.nodyssey` and the original UIKit/Compose application. A version bump alone does not fix a Room downgrade. This edition therefore selects **one fixed** `io.github.nodyssey.upstream-enhanced-v1` directory before opening any app-owned private store:

- `Library/Application Support/io.github.nodyssey.upstream-enhanced-v1/`: Room schema 20, settings (including saved phrases, histories and reports), post/comment drafts, DNS, offline preferences and offline files.
- Proxy/image-host preferences keep upstream backup exclusion, but strictly **inside the new root**. No old global preferences, credentials or Keychain values are imported. The original factory is reused with explicit root injection; its earlier-file move cannot leave this edition's root.
- `Library/Caches/io.github.nodyssey.upstream-enhanced-v1/`: Coil image cache and the sole root supplied to app cache clearing. Cache clear cannot sweep sibling legacy roots or Application Support.
- The root is stable across launches, version upgrades and login/account generations. This is a single device-local profile, **not multi-account isolation**. Original explicit sign-out cleanup remains scoped to the active graph.
- The original Apple Room factory keeps its defaults for other callers; supplying this edition's explicit root disables schema-1/2 and downgrade destructive fallback. Android factories/defaults are unchanged. Unsupported schemas in the new edition fail instead of deleting.

Every older sandbox location is retained, not read/adopted/copied/moved/deleted: the legacy root database/preferences/offline files, legacy excluded secrets, and build 64's `Application Support/io.github.nodyssey.single-local-v1/...`. No owner is inferred and no provenance/workspace/journal/recovery machinery is imported. Local history, drafts, offline downloads, app preferences and local notes start fresh in this edition; old bytes remain available only to their old implementation or an explicit future migration.

Authentication is deliberately unchanged: original browser UA resolution, WKWebView cookie bridge and shared `NSHTTPCookieStorage` remain the cookie authority; no cookie clear/import or auth rewrite is introduced. Actual login and the reported build-64 login deadlock are **not verified or claimed fixed**.

A re-signed overlay preserves the container only when iOS accepts it as the same app with compatible bundle identity/signing team. This unsigned IPA cannot guarantee that an install tool preserves the sandbox. Do not uninstall/reset/delete the old app to install it. No installed-device inventory was available or accessed; only synthetic temporary test stores are used. Parent review is still required before user delivery; device overlay acceptance is separate from archive success.

## Third-party provenance and licensing

Behavior inspiration, not bundled JavaScript:

- **NodeSeek Pro Max**, version **1.2.6**, author **用蚊香买榄菊**, declared license **GPL-3.0**.
- Pinned source URL: https://update.greasyfork.org/scripts/605053/NodeSeek%20Pro%20Max.user.js
- SHA-256: `a58b0fbcfbffb69fd4d234669951fb1b3ebe5c7e4f8a16e58bb0ac4252a0929d`.
- Source notice: “Based on NodeSeek Pro+; modified and maintained as NodeSeek Pro Max.” Original project: https://greasyfork.org/scripts/602733 .
- The original authors retain their rights; no copyright ownership or endorsement is claimed. The inspected userscript header supplies attribution/license but no separate copyright-year notice. Existing Nodyssey copyright/license notices and root GPLv3 `LICENSE` are retained.

This is an independent Kotlin implementation of selected behavior; no script body, third-party JS/CSS, icons or branding are copied. The app is still named Nodyssey. No GM runtime, remote code loader, AI key/provider, automatic attendance/post/upload, heuristic trust score or new credential is included. Any later distribution must retain these notices, the GPL license and provide corresponding source; distribution-platform terms are a separate review.

## Verification boundaries

Linux JVM compilation/tests exercise the production settings store, Compose text state, profile request guard and fixed edition path model using sentinel legacy files plus actual DataStore close/reopen. They do **not** execute Apple's factory/filesystem bindings, Room on iOS, cache clearing, UIKit IME behavior, dialog z-order, device navigation or an overlay install. The dedicated manual `ios-ipa.yml` archives the original application for generic iPhoneOS in Debug without running Apple tests. The delivery report records the exact source SHA, completed archive/run, verified IPA manifest and remaining device acceptance; archive success is not login or overlay installation acceptance.
