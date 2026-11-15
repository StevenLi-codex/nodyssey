# Preserving private workspaces — implemented backend ABI

Status: **production Kotlin implementation in the worktree, focused JVM gates passing**.
This is no longer a design-only proposal. Apple compilation/linking, simulator and
real-device over-install remain separate, unexecuted release gates on this Linux host.
No live account, credentials, commit or push was used.

## Native ABI (confirmed source contract)

Read or observe `session.privateBoundary`. Existing fields remain:
`phase`, `identityEpoch`, `requiresConfirmation`, `recoveryEligible`.
Additional fields:

- `canCreateWorkspace: Boolean`: recovery is idle and the shared session is signed in.
- `workspaceBinding: "LEGACY" | "SESSION_PROOF"`.
- `preservedData: Boolean`: a namespaced workspace has been selected; old storage was
  not deleted. This is not a claim that old data has a verified account owner.

Call `session.createPrivateWorkspace` with:

```json
{"confirmed":true,"identityEpoch":"<epoch displayed in the confirmation>"}
```

Success returns the complete boundary DTO, `phase=READY`, a new epoch,
`requiresConfirmation=false`, `workspaceBinding=SESSION_PROOF`, `preservedData=true`.
It returns only after persistent commit and live graph binding. It does not invoke
`session.resetPrivateStores`. Existing sanitized error envelopes remain unchanged.
Stale epoch, cookie-proof drift since the displayed epoch, unsigned session, active
browser/auth mutation and concurrent activation are rejected rather than queued.
A corrupt/unreadable router journal fails closed, not an automatic reset.

Password/browser authentication and private-store admission remain separate:
`SIGNED` plus `CONFIRMATION_REQUIRED` means authentication succeeded. Offer the
preserving action once `canCreateWorkspace` becomes true. Missing new DTO fields
mean unsupported. Native observers follow the selected graph; Swift does not need
to create a parallel data store or own Kotlin observer rebinding.

Integration reconciliation for build 59: the normal native transport unwraps
`{ok:true,data:...}`, so Swift receives the boundary DTO directly. Capability is
`recoveryEligible && sessionRepository.peek().isSignedIn`; READY has both flags
false, while idle UNKNOWN/TRANSITIONING requires confirmation. After `bind`,
`ensureContainer()` returns the new immutable graph: the explicit boundary read
and `session.sync` therefore report its epoch. `session.state` combines the shared
session and selected boundary, and all native observers switch through
`NodysseyApp.workspaces`. Swift accepts intermediate retired-graph epochs but
requires the complete READY receipt, final boundary, and signed session to agree
before mounting private UI. No reset, legacy adoption, or UI admission bypass is
part of this operation.

## Identity limitation

`SessionCookies.privateOwnerProof()` binds the origin and authentication-cookie
proof. It is **not** a verified stable account ID. Describe a **session workspace**,
not an account workspace. The exact proof survives relaunch; a rotated proof cannot
relabel or adopt an old space, even when the server account may be the same.

Suggested disclosure: continue with a new empty private space for this login;
previous local data stays on the device but is not opened or merged. A later login
may need another space. Reset/uninstall is not part of this flow.

## Ownership and storage

`IosGlobalServices` retains the cookie/session/auth, transports, global preferences,
DNS/proxy/image-host configuration, offline policy and global catalogue services.
`NodysseyApp` owns one router and replaces its `IosAppContainer` private snapshot.
Captured repositories never forward to a newly selected graph.

New storage lives under:

```
Application Support/io.github.nodyssey.private-workspaces/<site>/<random UUID>/
```

The root is backup-excluded and **outside** the old global Caches sweep. Each graph
owns Room `private.db`, both composer stores, private settings, provenance, offline
files and a Coil loader with `<workspace>/cache/image_cache`. Its DataStores use an
owned scope which is cancelled and joined on close. Room and the loader/cache are
closed only after private and general workspace leases have drained. Normal cache
clear receives only the active workspace cache directory, not the router root.

`WorkspaceSettingsDataStore` routes history, reports, notification seen counts,
clipboard post marker and keyword-alert baseline to the workspace. Other settings
keep their original global SSOT. It copies no legacy private values, preserves
legacy keys during public edits, and rejects cross-partition updates rather than
claiming a cross-file atomic transaction. Android factory defaults are unchanged.

Global boards, title rules and sticker catalogues are imported once into a separate
global Room database, through a read-only SQLite connection without running Room
migration on the source. Only `boards`, `title_keywords`, `my_stickers`,
`sticker_repos`, `sticker_folders` are selected. Private and derived post-ID tables
are not copied. Active workspaces mirror global title rules locally and rebuild
only their own regex hits. The original legacy database stays in place.

Existing legacy private paths/provenance are inspected without using the migrating
backup-exclusion factory. If legacy private files exist, the Apple startup path
quarantines the legacy graph before opening private Room/Coil. It does not move,
clear, delete, or adopt them. Global settings can still be read/changed independently.
Forum/third-party NSURLSession response caching is disabled; old system URLCache
files are preserved rather than reused or cleared.

## Durable activation / failure behavior

The router stores a versioned `PREPARING` or `COMMITTED` record in its own DataStore.
Explicit activation closes old admission, joins actual work (including late
non-cancellable cleanup), writes PREPARING, closes the old owned resources, opens a
fresh random graph, establishes fresh provenance, checks the proof again, commits
the pointer, prepares global catalogue mirrors and binds the live graph/Coil/
scheduler/observer source. It never retargets the retired graph.

Only a committed namespace with matching exact proof **and** complete READY
provenance may reopen. PREPARING, mismatched proof or interrupted provenance remains
closed; candidates are retained and not silently adopted or deleted. An explicit
new confirmation can retry with another fresh namespace. Failures do not report
success and retain closed admission. A crash after durable commit may reopen that
committed space for the exact proof; this is not adoption of an uncommitted candidate.

Scheduler work captures a graph and epoch, not just a mutable graph resolver inside
an already admitted job. Native operations hold the captured lifetime. Observers
switch through `NodysseyApp.workspaces`; old jobs cannot write into the new space.
Coil 3.6.3's actual `setUnsafe(ImageLoader)` (DelicateCoilApi), `ImageLoader.shutdown`
and `DiskCache.shutdown` APIs were checked against resolved artifacts.

## Focused verification and limits

Run:

```sh
python iosapp/tests/native_session_security_test.py --graph-integration
python iosapp/tests/owned_workspace_graph_test.py
python iosapp/tests/native_session_security_test.py
```

The graph-integration suite executes production native dispatch, boundary/router,
settings/Room repositories and scheduler admission regions with platform fixtures.
It covers persisted UNKNOWN with nonempty stores, guest browsing followed by login,
restart/exact-proof reopening, A→B isolation, stale/browser refusal, cookie drift,
late writers, PREPARING restart and observer rebinding. It inspects retired stores
through a newly owned reader after close/join, not an illegally reused DataStore.

The owned-graph suite compiles the **entire production `IosAppContainer` class**,
router, settings partition, catalogue importer and production `IosAppCacheStore`,
using real JVM Room/DataStore and explicit platform/global/Coil fixtures. It verifies
isolated drafts/history/offline storage, reopen, cache-clear preservation and the
read-only catalogue import's source database bytes/idempotence. This is not an Apple
startup or actual Coil/NSURLSession integration test. The original scratch red probe's
acceptance methods now live in the checked-in graph suite; its obsolete injected
fixture must not be interpreted as an Apple build gate.

Outstanding release gates: compile the actual Apple graph/factories and exported
framework on a Mac, exercise NSURLSession/WebKit and real Coil shutdown on device,
and over-install with a nonempty legacy application container. No Linux fixture or
Gradle skipped native task substitutes for those checks. No full SVG suite was run.
