# Native bridge security review — unresolved acceptance gates

Independent read-only review of committed bridge/core/platform changes from `ca98c21c47ddee7b3704417442d60e90bc828596` through `33d782448dde7baf600006639e047e48642196f2` returned **FAIL**. Parent checked the affected current source paths. These are source-derived causal traces, not executed iOS reproductions.

## Blocking findings

1. **High — persistent WebKit login survives sign-out.** `NativeAccount.kt` sign-out invokes the original account-sign-out service, which clears Foundation cookies but not the default WebKit cookie store. `NativeBrowserSession` seeds and drains that store; retained cookies can restore the old account. Acceptance requires coordinated browser ownership, awaited cookie removal, and a race test covering reopen/seed/drain during sign-out.
2. **High — account change outside explicit sign-out retains private stores.** `NativeBridge.reconcile` reconciles post caches, not unscoped draft DataStores/offline content. Browser/session-sync account changes and cold-start session loss need owner validation or guarded cleanup before exposing the next session. Quiesce old writers/downloads; preserve verified same-account drafts/offline content across ordinary relaunch.
3. **Medium — internal sign-in supersession never completes the Swift request.** Revision mismatch throws `CancellationException`, which the bridge intentionally does not deliver. If the Swift task itself was not cancelled, its checked continuation remains pending. Internal supersession needs a terminal outcome distinct from caller cancellation, and completed network authentication cookies still need reconciliation.
4. **Medium — old notification badges survive explicit sign-out.** Post-cache cleanup already writes the unauthenticated marker, so subsequent reconciliation can return false and skip `clearCounts`. Reset counts on identity transitions independently of whether post-cache reconciliation deleted rows.

## Status

A separate fix agent owns the native account/bridge/platform boundary and regression tests. No finding is closed by this document or by assigning a task. Fix evidence belongs in `swiftui-session-isolation.md`, followed by independent re-review and actual Apple compilation/runtime verification. No live account mutations were performed by the review.
