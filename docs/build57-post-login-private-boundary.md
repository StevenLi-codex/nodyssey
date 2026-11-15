# Build 57: successful authentication followed by private-data recovery

## Proven failure

The production path `NativeBridge.request("session.signIn")` → `accountAuthenticate` →
`NodeSeekSignInRepository` → `NodeSeekJsonClient` → cookie installation can return
`status=SIGNED` while `PrivateSessionBoundary.finishMutation` writes `UNKNOWN`.

Build 57 admits only an unchanged authentication-cookie proof at mutation completion.
A first login necessarily changes that proof. Even a fresh, READY guest installation
with **every protected store empty** therefore becomes locked. `reconcileLocked` cannot
repair this: the mutation writes a versioned UNKNOWN manifest, and its completed
`observed` cache short-circuits later same-proof reconciliation. This is not a failed
password, parser refusal, or evidence that the device actually contains legacy data.
The browser's final-drain path has the same changed-proof rejection.

There is also a distinct, intentional case: guest browsing itself writes protected
bytes. `boards.recent.record` persists `recent_boards`, and a guest thread load writes
Room `post_details`. Those bytes are not proof of ownership by the account that later
logs in. Nonempty guest, another account's, malformed, legacy, and interrupted stores
must remain preserved and inaccessible. A successful login alone cannot adopt them.
Auth-cookie rotation with nonempty stores remains conservative; a cookie digest is
not a stable server-verified account identity.

## Minimal change

- Mutation begin still closes admission, journals TRANSITIONING, and joins old writers.
- Only a previously verified READY state can capture an empty-inventory capability,
  and only **after** that drain. UNKNOWN/legacy/interrupted state never gets one.
- Password/2FA `SIGNED`, or an attained login/one-tap browser goal after final drain,
  can use that capability only when the complete physical inventory is still empty.
- Empty rebind writes complete provenance for the new proof, admits the new epoch,
  and never restores the guest epoch. It does not invoke any participant `clear`.
- Failed/refused/cancelled password operations and other browser goals do not opt in.
  Defaults stay false, including existing shared/Android callers.
- Auth result JSON retains `status=SIGNED` (authentication did succeed) and adds
  `privateDataStatus: READY | CONFIRMATION_REQUIRED` plus `privateBoundary`, mapped
  after final reconciliation. Consumers must explain successful authentication with
  preserved-but-locked local data, not imply that authentication failed or silently reset.

No data adoption, automatic reset, uninstall, credentials, live account, or live HTTP
was used. No change to the production inventory, raw repositories or Android defaults.
An existing versioned UNKNOWN manifest is deliberately **not** healed just because its
inventory happens to be empty on a later launch.

## Executed evidence

`python iosapp/tests/native_session_security_test.py --graph-integration --method successfulPasswordLoginAfterPublicStartupAdmitsEmptyStores`

- Before fix: `SIGNED` followed by `expected READY but was UNKNOWN`; exit 1.
  Artifacts: `/home/hermes/.hermes/cache/scratch/native-session-security-jvm-g65wdh8x`.
- After fix: READY, new epoch, private empty-draft read succeeds, real DataStore
  close/reopen preserves the rebound provenance; exit 0.

`python iosapp/tests/native_session_security_test.py --graph-integration --repeat 2`

- 22 named cases per invocation, zero failures/ignored on both final invocations.
- Covers exact production bridge/account parser/client, inventory and wrappers with
  actual temporary Room/SQLite and DataStore, startup observations, native browser
  start/goal/close, guest recent-board bytes, guest Room thread bytes, legacy private
  drafts/offline files, unexpected late bytes and malformed auth response after cookie.
- Artifacts: `/home/hermes/.hermes/cache/scratch/native-session-security-jvm-vfm1cy4t`.

`python iosapp/tests/native_session_security_test.py`: 16 cases, zero failures/ignored.
`python iosapp/tests/private_boundary_test.py`: 7 cases, zero failures.

These are JVM production-region executions, **not** an Apple build, WKWebView network
login, simulator or device reproduction. Foundation/WebKit callbacks, graph construction,
Coil and platform paths use disclosed fixtures; the browser test explicitly transfers
Foundation fixture output into the graph's SessionCookieStore authority. HTTP replies
and cookie acceptance are fixture-controlled; no claim is made about live credentials.

Scoped Spotless hook reported the three production files clean before reverting an
unrelated formatter-only image-method indentation change to keep this patch off SVG/image
scope. Compiler fixture warnings and Kotlin/Native unsupported Linux-aarch64 warnings
remain; Apple compilation/linking and device acceptance are outstanding.

## Remaining integration / device distinction

The Swift auth result model/presentation consumer is a separate integration owner.
It must consume the additive privacy status and explain SIGNED+CONFIRMATION_REQUIRED
without automatic deletion. Browser consumers can read the existing boundary after close.

A screenshot alone cannot distinguish the reproduced clean-login bug from genuinely
untrusted local bytes. If the installed device remains locked after the safe fix,
collect only sanitized `isSignedIn`, boundary phase/epoch/eligibility and, if approved,
participant IDs with physical-empty booleans. Never collect cookie values/digests,
accounts, private contents or unsanitized database/preferences dumps. Do not recommend
reset/uninstall as diagnosis. Existing UNKNOWN cannot safely be inferred to be clean
from the current cookie identity, and this patch deliberately preserves that limit.
