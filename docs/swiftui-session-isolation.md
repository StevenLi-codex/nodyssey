# Native session isolation — implementation and release blocker

## Status

**This is not a completed session-isolation fix. Finding 2 remains release-blocking.**
Count-before-session-publication ordering is also an open, reproduced failure
(finding 4); request-completion reset does not establish that stronger property.
The changes below address the reviewed browser-cookie cleanup path, internal sign-in
supersession, and identity-transition unread-count reset. They do not establish a
cross-repository writer barrier or persistent draft/offline ownership.

No shared/Android API, `IosAppContainer`, `NodysseyApp`, `NativeSettings`, or Swift UI
file was changed by this work. Existing supplement dispatch was preserved. No
commit, push, live login, or forum mutation was performed.

## Implemented changes

### Browser-cookie cleanup (finding 1)

`session.signOut` now enters `NativePlatform.signOut` while retaining the existing
account mutation/authentication gates. The existing browser-owner authority also
excludes cookie deletion:

1. A live browser returns terminal `BROWSER_BUSY`. Merely stopping its observer is
   insufficient: Swift owns `WKWebView.stopLoading`, and an active view can still
   write new cookies. The caller must close the browser and retry; it must not
   silently retry a sign-out mutation.
2. If browser close has started, await its serialized stop/final drain and binding
   poll cancellation. No new browser can claim the lease while cleanup runs.
3. Enumerate the default WebKit cookie store; delete the active site's configured
   authentication cookie names on domains applicable to its session URLs, across
   all paths. Await each deletion callback, then read back and refuse success if
   an applicable authentication cookie remains. Unrelated WebKit domains survive.
4. Invoke the existing `AccountSignOut` implementation, which remains the
   Foundation/session authority. It clears Foundation and publishes signed-out
   only after its own repository cleanup, after the WebKit deletion above.

The cleanup lease outlives cancellation of the native request. A failed final
browser drain neither publishes nor marks the lifecycle finished; the browser
lease is retained rather than enabling another seed. A subsequent successful close
or sign-out drain releases it. There is no second cookie mirror.

**Limit:** existing `SessionCookies.clearSession()` clears the whole Foundation
store. This patch preserves that repository behavior; only WebKit removal is
site/auth scoped. The broader writer-quiescence problem below still applies to
sign-out's repository cleanup and other in-flight native requests.

### Authentication supersession (finding 3)

A revision mismatch produces `SIGN_IN_SUPERSEDED`, not `CancellationException`.
The check runs both after the sign-in response and after `syncAwaitingSession`,
which can suspend. The existing cookie jar is synchronized if a delayed response
installed cookies, including when genuine caller cancellation is observed.

Ordinary authentication exceptions now clear stale challenges and synchronize the
existing cookie jar before rethrowing the original exception. A transport can
accept Set-Cookie before response parsing throws. Previously only the cancellation
catch synchronized: `peek()` was signed-in while published `state` stayed signed-out.
The permanent regression reproduces that exact failure, then verifies the minimal
`NativeAccount` exception catch. `INTERNAL`/`UNPARSABLE` stay sanitized errors, not
`SIGNED`; genuine caller cancellation still has no callback. This correction does
not add a publication barrier, revoke an already-issued session, or turn a refused
repository outcome into an exception.

`NativeBridge` reconciles session/count state in a non-cancellable `finally` around
session-changing operations, before a success/error completion is emitted. Genuine
caller cancellation still suppresses the completion and propagates cancellation;
it is not translated into an ordinary failure.

**ABI:** request shapes and callback signatures are unchanged. The frontend must
handle the sanitized `SIGN_IN_SUPERSEDED` terminal error. Supersession is not a
promise to revoke a server session that has already been issued; the shared cookie
session remains authoritative, and stale `SIGNED` operation success is suppressed.

### Unread-count reset (finding 4)

`NativeBridge.reconcile` clears counts on identity change independently of the
post-cache deletion boolean. Reconciliation now also happens after session-changing
operations, including their error/cancellation paths. Consequently explicit
sign-out does not depend on another request or network refresh to clear badges,
and an A→B transition clears the previous counts even when the post marker was
already cleared.

**Limit:** an unrelated old notification writer can still race without the global
writer barrier required by finding 2. More immediately, session publication itself
can precede the reset: `DefaultAccountSignOut` publishes through `session.signOut`,
then the native final reconciliation can suspend in `PostRepository.reconcileSession`
before clearing counts. A retained regression that delays this dependency by 50 ms
observes signed-out with **9/4/3** counts, not zero. It fails in all three follow-up
runs. The original counts-at-publication assertion remains unchanged; it was not
weakened into an assertion only after request completion. The delayed schedule is a
separately runnable **open release gate**, not a skipped test or expected-success
test. No NativeBridge/shared publication-order workaround was made in this narrow
follow-up. Request-completion reset is verified; publication ordering and global
quiescence are not.

## Finding 2: confirmed, not fixed

The allowed native files cannot safely infer persisted ownership or stop every
writer using the current interfaces:

- `IosAppContainer.database` is private. `PostRepository.reconcileSession` exposes
  only a boolean; `cache_session` is maintained for post data, not a transaction
  covering drafts and offline content. `DefaultAccountSignOut` overwrites that
  post marker before the next reconciliation.
- `DefaultPostComposerRepository` and `DefaultCommentComposerRepository` persist
  global drafts with no account provenance. Assigning the current cookie identity
  to old drafts on launch would fabricate ownership.
- `RoomOfflineLibrary.clearAll()` deletes rows/files without cancelling or joining
  `drainQueue`. Its background scheduler jobs are not owned by `NativeBridge`.
  Per-observer `collectLatest` does not join other observers/requests or scheduler
  writers before cleanup.
- `NativePlatform.image` separately calls post reconciliation before reading the
  existing offline/image stores. Foreground/background scheduling can also resume
  outside native request dispatch. A bridge-only mutex cannot cover those paths.

The retained RED regression uses a real file-backed DataStore and the production
`DefaultPostComposerRepository`, `SessionRepository`, `NativeAccount`, and
`NativeBridge`: after A saves a draft and cookies transition to B through
`session.sync`, the A draft remains readable. No fake draft store supplies that
result.

### Required scope extension

Supply an additive shared API for persisted **private-store** provenance and a
joinable writer barrier (including `RoomOfflineLibrary`/scheduler drains), then
wire all native request, observation, image, browser publication, and lifecycle
entry points through one boundary. Cleanup must finish before ownership is
committed or new-account reads resume. Interrupted cleanup must remain untrusted
on restart. Unknown provenance must deny protected reads until a deliberate reset
or a justified migration; do not auto-assign ownership or delete on every launch.
Same verified owner across relaunch must retain drafts/offline content.

This requires touching files beyond the assigned native ownership; that need was
reported during the work. No speculative shared API or destructive cold-start
fallback was added. **Do not ship this patch as full account isolation.**

## Behavioral evidence

Commands run from the repository root with cached pinned Kotlin 2.4.20/JDK 21:

```sh
python iosapp/tests/native_session_security_test.py
JAVA=/home/hermes/.cache/nodyssey-build/jdk21/bin/java \
  python iosapp/tests/native_platform_core_test.py
python iosapp/tests/native_supplement_test.py

# Intentionally still RED — separately runnable, never silently skipped:
python iosapp/tests/native_session_security_test.py --open-isolation
python iosapp/tests/native_session_security_test.py --open-publication

# Bounded, isolated JVM repeat runs, with named JUnit events and unique artifacts:
python iosapp/tests/native_session_security_test.py --repeat 20
```

Observed RED → GREEN checkpoints (logs in `$TMPDIR/session-security-*.log`):

| Regression | Recorded RED | Subsequent GREEN |
| --- | --- | --- |
| delayed sign-in + cancel/sync | expected one completion, got zero (`red-auth`) | both complete with `SIGN_IN_SUPERSEDED` |
| cancel during session settling | stale `status: SIGNED` (`red-settle`) | terminal superseded result |
| sign-out / A→B counts | counts remained 9/4/3 (`red-counts`) | zero without refresh |
| default browser auth after sign-out | auth cookie remained (`red-cookies`) | deletion awaited; unrelated domain retained |
| transport result after caller cancellation | published session remained signed-out (`red-late-cancel`) | jar/published session agree; no callback |
| error/cancel count reconciliation | four stale-count failures (`red-failure-counts`) | counts reconciled before request termination |
| interrupted final browser drain | events were `[stop, publish]` (`red-drain`) | no publish until a successful retry |
| A→B persistent draft | prior draft remains (`open-isolation`) | **not green; release blocker** |
| ordinary auth error after cookie + supersession | `peek` signed-in, published state signed-out | original sanitized error, synchronized state, no `SIGNED` |
| session publication with suspending reconciliation | observer sees old 9/4/3 counts | **not green; open publication gate** |

The final follow-up security fixture passes **16 tests per suite across 20/20
bounded full-suite repeats (320 test executions, zero failures/ignored/timeouts)**.
It covers normal authentication, internal supersession, genuine cancellation,
ordinary errors with and without installed cookies, parser errors, and ordinary
error after caller cancellation. The exact ordinary-error regression was first
observed RED (one assertion failure), then GREEN after only the exception catch.
An earlier intermediate fixture passed 5/5 full suites of 11 tests; these are not
counted in the 320 final-fixture executions. Separate open gates still exit nonzero:
publication **3/3 failed**, persistent draft isolation **1/1 failed**.

The earlier platform-free iosTest result was **6 tests**, including close-during-seed
and interrupted-drain ordering; the earlier supplement/settings result was **17
tests**. Neither was rerun by this narrow authentication/harness follow-up.

### Harness lifetime correction

The review reproduced a dot-only hang because the fixture cancelled the only
producer of `publishedCounts` before awaiting it. The fixture now awaits the event
with a deadline while its collector remains alive, and cancels/joins the collector
in `finally`, including assertion failure. Request helpers await both terminal
callbacks and actual request Job completion; fixture waits/joins are bounded and
WebKit fixture deletion flags/jar are reset. This corrects test lifetime, not a
demonstrated production deadlock.

Each Python invocation creates a unique scratch directory. Kotlin compilation is
bounded to 90 seconds, Java runner compilation and each JUnit suite to 30 seconds.
Named START/END/FAIL events and per-run JSON/logs preserve the failing method.
On deadline the wrapper terminates only its owned process group, escalates to KILL
if necessary, reaps its child, and returns 124. Both normal TERM cleanup and a
TERM-ignoring child's KILL cleanup were exercised successfully. The final fixture
runs had no timeout. Process deadlines diagnose hangs; they do not replace the
collector-lifetime correction.

Detailed evidence is recorded in
`$TMPDIR/nodyssey-auth-followup.json`, with unique artifact paths and exact counts.

### What the Linux harness does and does not prove

The security harness compiles exact production account/bridge files, exact extracted
browser ownership/session/lifecycle code, and the existing shared
`WebKitCookieBridge`. Production session, notification and sign-out repositories
run. A generated graph fixture injects dependencies; unused domain dispatchers
return null. Post-cache/unused cleanup dependencies use explicit test doubles.
Settings and the open-isolation draft regression use real temporary DataStore files
whose scopes are cancelled/joined before deletion.

`SessionFoundationFixture.kt` and `SessionWebKitFixture.kt` are **runtime callback
fixtures**, not real Apple implementations or evidence of Apple scheduling,
persistence, domain behavior, or API compatibility. Tests establish orchestration
with controlled callbacks only. This distinction is intentional: no Apple success
is claimed from them. The standalone platform harness executes the actual
platform-free region and actual `NativePlatformTest.kt` methods.

## Remaining Apple / integration gates

- Kotlin/Native compilation of `iosMain` and `iosTest`, including real
  `WKWebsiteDataStore`/`deleteCookie` interop and Objective-C export.
- Xcode compile/link and Swift checked-continuation tests for both terminal
  supersession and genuine caller cancellation.
- Simulator/device test using actual Foundation/default WebKit stores: establish
  fixture auth cookies, close/sign out, reopen/seed/drain, and verify no restoration.
  Include cookie domain/path variants, close during seed, overlapping close/sign-out,
  cancellation during deletion, and browser-busy UI handling.
- Shared/Room/offline concurrent-writer and cold-start provenance tests after the
  required scope extension. Include A→B without sign-out, browser transitions,
  lost cookies on cold start, interrupted cleanup, and same-owner preservation.
- Scoped formatting is not a repository-wide gate; other agents own concurrent
  changes. Linux reports Kotlin/Native targets unsupported, not Apple-build success.
