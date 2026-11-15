# iOS build 60: single device-local profile

This replaces the unfinished private-workspace feature. There is no workspace
activation, account switcher, recovery/reset button or account-scoped local namespace.
Normal sign-in, browser sign-in, sign-out and subsequent sign-in remain available.
**This is single-account use, not multi-account support or an isolation guarantee.**
If a different server account is used later, this same device-local data remains.
Server authorization is still enforced; local admission never grants server access.

## Storage contract

Before opening local repositories, the process selects one fixed, versioned path:

`Application Support/io.github.nodyssey.single-local-v1/<site>/`

The same path is reused after sign-in, sign-out and process restart. It holds the
new Room databases, drafts, private settings/history/reports/counts, offline files,
and `cache/image_cache`. Cache clearing is restricted to this profile's `cache`.
The root is backup-excluded. There is one process graph and one DataStore instance
per file; no router, activation journal or persisted cookie-to-data ownership journal.

Old databases (including UNKNOWN or interrupted provenance), drafts, offline files,
image caches and prior workspace directories are not opened, migrated, adopted,
cleared or deleted. No old Room catalogue import is performed. Existing cookies and
global DNS/proxy/image-host configuration retain their existing owners. The mixed
legacy settings file has a **positive explicit public-key allowlist**; only those
settings are exposed/updated through the shared view. Private and unknown future
keys are not copied into the new profile or exposed, and public updates retain them.
New non-allowlisted keys belong only to the new local settings file.

Consequently the new local history/drafts/library start empty. The old data remains
on the device but is inaccessible in this version. This is not a recovery/migration
feature. Do not uninstall, clear all app data or reset old stores to use this build.

## Authentication lifetime

The iOS graph alone opts into `singleAccountLocal`; its shared default is false and
Android wiring is unchanged. Cookie changes do not classify local bytes as UNKNOWN.
The existing request barrier still closes admission, cancels/joins old work and
non-cancellable file/network cleanup, rotates an opaque epoch, resets notification
counts, publishes the actual auth state, and reopens admission. Auth failure and
cancellation keep their own error/result semantics. A cancellation during the old
writer drain also reopens the local profile after the drain. Stale callbacks and
unreconciled cookie drift remain rejected. The browser still owns its final cookie
drain and sign-out cannot race a live browser. No blanket no-op barrier is used.

The native boundary ABI remains an internal request-lifetime signal. Swift retains
its generation fencing and briefly shows progress during transitions; it no longer
offers a private-space/recovery interface. `session.resetPrivateStores` is unsupported.

## Focused verification

- `python iosapp/tests/owned_workspace_graph_test.py`: complete production iOS local
  graph and cache-clear implementation with real JVM Room/DataStore, platform/global
  service/Coil fixtures. Preserves legacy sentinel bytes and mixed settings; nonempty
  guest history/draft → login → logout/login → restart; joins delayed writers; rejects
  stale publications; recovers cancelled pre-auth drain; forbids destructive reset.
- `python iosapp/tests/native_session_security_test.py --single-local`: production
  native auth dispatch/parser and browser orchestration, fixture graph and WebKit,
  normal/error/cancel/superseded auth plus cookie-deletion lifetime.
- `python iosapp/tests/private_boundary_test.py`: unchanged strict default semantics,
  real file-backed provenance/repositories. This is not an Android device test.

JVM fixtures are not Apple startup, WKWebView, live login or over-install evidence.
The dedicated `ios-ipa.yml` archives the actual complete Debug iPhoneOS target with
bundle `io.github.nodyssey`, build 60, without the full SVG/simulator suite. Delivery
must independently verify the successful archive log, manifest hash/size, IPA ZIP,
Info.plist and all Mach-O platform slices. An unsigned IPA requires signing; static
archive verification does not establish a device install or a successful live login.
