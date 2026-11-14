# Foundation / Account / Editor / Settings review — unresolved gates

Independent review batch `deleg_cb161de2` returned FAIL in both scopes. Findings are source-derived causal traces, not executed iOS reproductions. Complete reports were delivered to the parent; none is closed by assignment. Fixes require behavioral regressions, independent re-review, and applicable Apple execution.

## Account / Foundation

- **FA-1 (high): false password-change success.** `NativeAccountScreens.swift:59–69,79–86` and `AccountMutationState.swift:13–15` promote unknown writes to verified after generic refresh. Session snapshot/2FA reads cannot establish password-change success. Only acknowledged write or operation-specific authoritative evidence can justify saved status.
- **FA-2 (medium): validation locks out further writes.** Definitive `INVALID_ARGUMENT` from invalid block regex becomes uncertain/blocksWrite, while the generic presentation exposes no recovery. Release the gate for proven pre-write rejections, retain explicit read-only reconciliation for unknown outcomes.
- **FA-3 (medium): profile never initially fetched.** Profile and MyTopics/MyComments observe Room-only `profile.self` with no initial network request. Null cache can leave no header/content/retry. Start a separate lifecycle-owned initial request, preserve observation, expose retry/failure when empty.
- **FA-4 (medium): refresh cancels profile observation.** Same `NativeStore.load` cancels its observer. Refresh through independent request state and verify subsequent repository updates still arrive.
- **FA-5 (medium): clearance change destroys navigation.** Real `SessionRepository` increments generation when `hasClearance` changes even if identity does not. Foundation resets paths/sheets for every generation change; its clearance test incorrectly keeps generation fixed. Separate opaque identity epoch from general retry/reload generation. Do not infer identity from signed-in boolean or expose cookie fingerprints. Same-signed-in A→B must still invalidate.

FA-1–4 assigned to Account owner. FA-5 coordinated between Foundation owner and backend security reviewer; backend contract must be established before implementation.

## Editor / Settings

- **EDITOR-1 (P1): dirty close silently loses input.** While load incomplete/failed or pendingRestore unresolved, fields remain editable but saveDraft returns without persistence; flush appears successful and close dismisses. Require explicit restoration/current-buffer/discard decision and awaited save without silently overwriting the existing draft.
- **EDITOR-2 (P2): accepted message resurrects.** Tab disappearance caches pending A; later send acceptance clears live A but not cache; next appearance restores A and enables another send. Consume cache only for new-editor initialization, remove only accepted submitted revision, preserve newer input.
- **EDITOR-3 (P2): permanent dismissal lacks resource teardown.** Owned photo copies and uploads survive ordinary close; delayed picker callbacks can attach to a closed composer. Permanent dismissal must invalidate callbacks, cancel/join consumers and release copied files, distinct from temporary tab/navigation disappearance.
- **SETTINGS-1 (P2): completion clears newer keyword input.** Submit A, type B, successful A completion clears B. Add revision-aware completion or prevent editing while pending, retaining generation guards and failure preservation.

Editor and Settings fixes assigned separately with production-behavior tests. No live password changes, messages, uploads, or forum writes are authorized as verification.

## Independent re-review and parent reruns

Re-review `deleg_640bd630` is **FAIL**; full artifact `/home/hermes/.hermes/cache/scratch/nodyssey-account-editor-settings-rereview.json`. Targeted FA-1/3/4, Editor-2 and Settings-1 corrections are present, but three integration defects remain open:

- **REREVIEW-EDITOR-ROUTE (high):** same-generation sheet/path replacement and outer sheet Close bypass the editor's awaited departure. Foundation owner must connect actual route callbacks, preserve the screen on failed save, and distinguish temporary disappearance from identity-driven invalidation without saving into a new account.
- **REREVIEW-EDITOR-DRAIN (medium):** production callback cancellation resumes Swift before Kotlin's Job/reader terminates. Awaiting the Swift task cannot authorize temporary-file deletion; require actual platform termination acknowledgement or file lease, tested through production CallbackNativeTransport.
- **REREVIEW-ACCOUNT-RECOVERY-DRAFT (medium):** keyword read-only reconciliation still clears newer input. Recovery must preserve text/kind revisions, including A→B→A, without another write.

Parent independently executed Account **21 tests**, Editor **29 tests**, and the updated normal Settings runner (**26 base and 61 action-inclusive checks**, 61 distinct); all passed. These passing tests do not cover or close the new integration findings. The Settings scratch-only runner gap is resolved in the working tree and real Mac execution verified. Foundation changed during review; its final integrated source requires re-review. Fix ownership is split among Foundation route integration, Swift/platform drain integration and Account recovery; no release claim.

## Follow-up scoped passes

- Account recovery re-review `/home/hermes/.hermes/cache/scratch/nodyssey-account-recovery-rereview.json` passed with no scoped findings. Parent reran the updated **31 Account tests**, all passed. FA-1–4 and keyword revision recovery are accepted at the source/Swift behavior level; full iOS integration remains pending.
- Editor drain re-review `/home/hermes/.hermes/cache/scratch/nodyssey-editor-drain-rereview.json` passed at source/Swift callback-adapter level. Parent reran **38 Editor tests**; reviewer independently ran those 38 plus **5 focused Core drain tests**. Do not call this an independent rerun of the full 25 Core tests. Premature file deletion is addressed in the reviewed scope; generated Kotlin export/linkage and actual NativeRequest finally/structured-child termination tests remain gates.
- **REREVIEW-EDITOR-ROUTE remains open** under the Foundation owner. Neither scoped pass approves route removal or the wider in-progress shared isolation architecture.

## Retained gates

Main editor source handoff commits all fields, snapshots all fields, then blurs before action; marked-text replacement protection remains required. Two UIKit tests and real IME handoff have not been executed by the review. Mac tests/signature fixtures do not prove UIKit delegate timing.

Known baseline gaps (date grouping, floor share card, camera, notification/diagnostic/theme capability differences, message/edit draft persistence) remain separate from these defects. Full native compile/launch success is not complete route or data-safety acceptance.
