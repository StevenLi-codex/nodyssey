# SwiftUI account/profile/auth UI

## Integration

`NativeAccountScreens.make(destination:)` owns all 12 assigned routes: Profile, SignIn, AccountSettings, AccountProfileFields, AccountSecurity, AccountContact, AccountBlockList, AccountPreferences, UserSpace, Follow, MyTopics and MyComments. Unknown routes return nil; malformed required UserSpace UID renders an error rather than UID 0. Files live exclusively in `iosapp/Nodyssey/Native/Account/`, with tests/tooling in `iosapp/NativeAccountUITests/`.

The factory uses the actual `NativeAppModel.request` / `NativeStore` transport, canonical integer JSON, existing repositories, NativeTurnstile, NativeBrowser, NativeRemoteImage and NativeRichTextView. There is no production mock, secondary account store, guessed HTTP endpoint, embedded Compose screen or generic account web fallback. Cross-domain navigation uses `app.open` / `app.openLink`; `siteOrigin` resolves relative Markdown links against the active site, preserving quote floors.

Include domain-owned `Resources/{en,zh-Hans,zh-Hant}.lproj/Account.strings` in the app bundle. Existing translated Localizable keys are reused. No App.swift, project, workflow or other agent's implementation was edited.

## Implemented surfaces

| Route | Native behavior |
|---|---|
| Profile | Session-driven guest/member UI, observed own profile, avatar/name/UID/level/balances, own-space and content/follow/assets/account/tool/settings navigation. Attendance is delegated to the real native Assets route. |
| SignIn | Username/email, secure password, actual Turnstile token/reset, native six-ASCII-digit OTP, single-flight request, opaque challenge handle. Web login, forgotten password and registration use the platform login goal (no guessed URLs); one-tap is shown only when platform context exposes a provider path. |
| AccountSettings | Refreshed profile, account subroutes and confirmed shared `session.signOut`, followed by session readback. |
| AccountProfileFields | PhotosPicker, native image preview, actual PNG/JPEG/GIF detection, 6 MiB decoded limit; HEIC/other UIImage-decodable input converted to JPEG. Explicit upload confirmation. Bio/signature/Readme form, shared Markdown previews, confirmed save and profile-fields/profile readback. |
| AccountSecurity | Current/new/confirmation secure inputs, shared minimum length of 8 UTF-16 units, mismatch guard, simple length strength hint, password-change confirmation. Reads 2FA status, confirms enrolment with password, hands the transient otpauth URI directly to installed authenticator, reports missing app and refreshes on foreground. |
| AccountContact | Email/verified state, explicit site-owned email management browser, Telegram status/avatar/name, confirmed platform Telegram binding and confirmed unbinding/readback. Foreground/dismiss refresh. Phone unavailability is explained rather than an inert control. |
| AccountBlockList | `titles` initial tab, users and title/regex rules, add/remove confirmations, shared regex validation, search, shared showBlockedContent setting. Errors remain visible and reads can retry without resubmitting. |
| AccountPreferences | Authoritative holiday theme and allowed trade/life/photo-share boards. Native confirmation, remote write and readback; existing bridge owns local mirror synchronization. No second settings persistence. |
| UserSpace | Exact UID, profile, stats/Readme, topics/comments, own-account-only collections based on authoritative self UID (never trusts caller `isSelf` for access). Follow/unfollow confirmation/readback, real message navigation, private user-note edit/save/readback. |
| Follow | `showFollowers` initial tab, real following/follower requests, stable UID deduplication, local name search, refresh/error/empty and user-space navigation. |
| MyTopics / MyComments | Own UID from observed profile, real space pages, previous/next/jump/retry, current-page text search, topic-board filtering, current-page reverse order, comment excerpts and post/floor navigation. |

## Lifecycle and safety

- Passwords, OTP, verification tokens, enrolment URI, photo bytes and challenge handles remain transient. They are neither logged nor written to preferences/files. The UI never displays raw NSError/server messages.
- Sign-in owns its Swift request task. Cancel/dismiss/session change cancels it, invalidates epoch tickets, clears sensitive fields and invokes `session.cancelSignIn` in a cleanup task that outlives disappearance. It does not call `session.sync` while a native OTP challenge is active. `SIGN_IN_SUPERSEDED` is terminal, clears the form and is never retried automatically.
- Sign-in cancellation uses SwiftUI `dismiss`, not `resetNavigation`, retaining the originating tab stack. The cancel button remains available during a native sign-in request.
- Mutation state distinguishes acknowledged write plus readback from unacknowledged outcomes. A failed acknowledged read says saved-but-refresh-failed, never failed-save. Readback after an unknown observable-value write yields **reconciled, not saved**; password/enrolment outcomes remain unknown and blocked because status reads cannot prove them. Locally rejected input is editable without a write. Explicit recovery runs **only the read**, independently of generic error presentation; it never repeats a mutation. Native confirmation precedes account/profile/social/preferences/notes/block writes.
- Views clear transient state/cancel work on generation changes/disappearance. Self-profile screens use AccountSelfProfileState: a lifecycle-owned initial request alongside a Room observer, with separate NativeRequestState instances for refresh and observation. Its visible snapshot is generation-gated even before SwiftUI restarts the task. Other shared NativeStore consumers retain their existing invalidation. This does **not** establish backend account isolation. WebKit signout, browser/account-change draft/offline ownership, supersession completion and badge cleanup remain backend security gates tracked in `swiftui-security-review.md` / `swiftui-session-isolation.md`. No UI-only cleanup is claimed to fix them.

Actual controls have the required parent XCUITest identifiers:
`native.profile.settings`, `native.profile.signin`, `native.signin.account`, `native.signin.password`, `native.signin.cancel`.

## Executed verification

```sh
python3 iosapp/NativeAccountUITests/run-mac-tests.py
python3 iosapp/NativeAccountUITests/run-mac-tests.py --typecheck-ui
```

The approved nested SSH runner stages only owned sources/tests plus read-only NativeCore/Rendering dependencies under `/Users/steven/.cache/hermes-build/nodyssey-account-ui`. It removes temporary Swift packages afterwards.

- **10 Swift Testing behavioral tests passed** on Apple Swift 6.4.2. Actual production Foundation state files are copied into the test package, not reimplemented. Tests cover cancellation/late challenge rejection/secret clearing, ASCII OTP validation, mutation single-flight and confirmation, readback-versus-write failure, session invalidation, password validation, avatar type/size rejection, page identity above 2^53, stale-page/session suppression, active-site link and quote-floor routing.
- Initial RED runs failed because new state types were not yet implemented. A subsequent executed behavioral RED caught acceptance of page 1 while page 2 was requested (`an error was expected but none was thrown`); storing/validating the requested page made it GREEN. Swift Testing mutating-call macro capture was fixed in test scaffolding. No synthetic live responses or live account/security/media writes were used.
- **All account SwiftUI sources passed a macOS signature typecheck** together with the real renderer and NativeCore module. Tooling-only throwing UIKit/Kotlin/Foundation contract stand-ins are clearly labeled and never part of the app. The SDK was MacOSX26.5, language mode Swift 5, macOS target 14 because macOS newPassword/OTP content types have different availability from iOS. This does not validate real UIKit/Kotlin export/linkage or iOS deployment availability.
- CLT emits framework-search-path warnings in SwiftPM and deprecation warnings for the iOS-16-compatible one-argument onChange overload during macOS checking. Intermittent SSH banner timeouts were retried; the final two commands succeeded.
- Source inventory checked all 12 factory routes and found no account UI operation string absent from the three bridge contracts. This inventory is not a runtime test.

## Explicit remaining acceptance / scope gaps

Do **not** mark the full baseline inventory complete from this source delivery:

1. Full Xcode/iOS build, actual Objective-C export signatures, UIKit/PhotosUI callbacks, all locale resources, simulator navigation XCUITests, device accessibility, browser/Turnstile lifecycle and keyboard/OTP behavior require parent Apple CI. No Xcode/simulator/device execution is claimed here.
2. Avatar photo-library selection is implemented; camera capture/cropping is not. No camera privacy key/project setting was added outside ownership.
3. The existing space endpoints expose neither global query/board/sort arguments nor comment category metadata. Search/filter/reverse-order are explicitly labeled **current-page-only**; comment board filtering is not invented. Global MyTopics/MyComments filtering requires a bridge/repository extension.
4. The original rich editor formatting toolbar is not duplicated in the profile fields; native text inputs plus shared Markdown preview are provided. The password-strength display is a length hint, not the original character-variety scorer or an entropy claim.
5. Email change, Telegram binding and TOTP enrolment completion/disable remain genuine site/authenticator-owned flows because no native mutation endpoint exists. Opening an authenticator is not reported as enabled 2FA. The UI reads authoritative status after returning.
6. Profile attendance/leaderboard lives behind its Assets navigation entry, not duplicated inside Profile. Library owner/parent verifies those actions.

## Account review fixes FA-1 through FA-4

- **FA-1:** `AccountMutationState.refreshed` can reach `verified` only from an acknowledged write (`reading`/`savedNeedsRefresh`). Unknown observable-value writes become `reconciled`, with copy explicitly saying the original write was not confirmed. `account.changePassword` and `account.beginTwoFactor` cannot resolve uncertainty through status reads and remain blocked. The actual production `AccountAction` coordinator now lives in `AccountActionState.swift` and is exercised directly by Swift Testing, not reimplemented in a test double.
- **FA-2:** Blank keywords and malformed regex input are rejected in a local, pre-dispatch validation phase (`rejected`), retaining editable input and permitting corrected submission. The regex preflight uses Foundation syntax validation of the trimmed, 200-UTF-16-unit pattern; Kotlin remains authoritative. Only this local rejection is proven not to have written. Generic bridge/server `INVALID_ARGUMENT`, `AUTH_REQUIRED`, `INTERNAL`, `NETWORK` and `TRANSPORT` are deliberately **not** broadly classified as pre-write: an exception can occur after side effects. These cases expose a dedicated **Reload status (read only)** control, including for codes whose generic failure view has no retry. Recovery is single-flight, ticket- and generation-checked, and cannot replay a write.
- **FA-3:** Profile, MyTopics and MyComments now run a self-profile request with `refresh:true` alongside observation even when Room initially emits null. Initial load/error state is separate from observation. A null non-loading profile has visible unavailable/reload UI, and a failed initial read keeps its error visible until explicit retry.
- **FA-4:** Pull refresh and retry load a separate request state, never the active observer. Room remains the visible source of truth; null emissions clear the snapshot, and later Room changes continue to render after a failed refresh. Both paths cancel with the screen lifecycle. Generation changes hide old data before task restart and suppress stale callbacks/errors.

### Executed review regression evidence

Commands above were rerun using the approved Mac CLT runner. Final `Verification/fa-final-tests.log` reports **21 tests passed**, Apple Swift **6.4.2**, Swift Testing **2403**. `Verification/fa-ui-typecheck.log` reports **Account UI macOS signature check PASS** against MacOSX26.5 / macOS 14 (Swift 5 mode). These are not Xcode/iOS/UI-automation passes. The tests use synthetic callback transport fixtures and the actual production coordinators/state plus NativeCore; no server/account mutations occur.

Behavioral RED→GREEN logs under `iosapp/NativeAccountUITests/Verification/`:

| Log pair | Executed regression before fix |
|---|---|
| `fa1-red.log` / `fa1-green.log` | Unknown write incorrectly became verified/saved after a successful read. |
| `action-red.log` / `action-green.log` | Actual password coordinator unlocked after unrelated status read; malformed regex dispatched a write and blocked corrected input. |
| `recovery-red.log` / `recovery-green.log` | Double refresh started two reads; old-generation refresh marked verified and cleared the failure; stale recovery could start again. |
| `profile-initial-red.log`, `profile-refresh-red.log` / `profile-green.log` | Null Room did not trigger an initial request; pull refresh cancelled the observer and lost future Room updates. |
| `profile-generation-red.log` / `profile-generation-green.log` | Old profile remained exposed between generation change and task restart. |

Final regression coverage also verifies acknowledged-write/readback-failure recovery without replay, conservative error classification and explicit recovery availability, null-profile fetch failure/retry, disappearance cancelling initial fetch plus observer, and late callbacks after replacement. CLT search-path/deployment warnings and macOS deprecation warnings remain; one SSH banner timeout was retried successfully. Existing full-Xcode CI evidence for the earlier revision does not verify this patch; parent Apple CI must build/link and run the separate navigation/Profile XCUITests.

No commit, push, or live authentication/security write was made. No Foundation, App, Kotlin, project or workflow file was changed by this fix.

## Read-only keyword recovery follow-up

`REREVIEW-ACCOUNT-RECOVERY-DRAFT` is fixed by binding the block screen's text and regex toggle to `AccountKeywordDraft`. The screen uses its production `perform` helper with the real `AccountAction`; tests execute the same helper rather than supplying a no-op read closure. `AccountPendingWrite` now captures an optional draft revision when the Add confirmation is opened. Every text/kind assignment advances the revision, including A → B → A and kind round trips.

- `keywords.get` recovery never clears input. Only the coordinator's guarded acknowledgement callback can clear an **add**, and only when captured revision and kind still match. Removing a rule cannot clear an unsubmitted draft.
- Readback publication checks cancellation and session generation inside the helper, before assigning the list; the coordinator's later checks cannot protect a closure's earlier UI side effects. A result for another regex kind is not published into the current list.
- Existing FA-1 password uncertainty blocking and FA-3/FA-4 observer coordinators were not changed.

The approved Mac runner executed **31 tests successfully** (Apple Swift 6.4.2 / Testing 2403), including the previous 21 tests. New coverage exercises failed A → edit B → reconciliation, edits during suspended recovery, regex switches, A → B → A, changes before confirmation, acknowledged success, acknowledged-read failure/recovery, remove, late cancellation/session replies, single-flight recovery and no second write. The macOS UI signature check also passed. Existing CLT framework/deployment and macOS `onChange` deprecation warnings remain. No iOS/UIKit/Kotlin link or device/UI automation is implied.

Executed TDD logs are in `/home/hermes/.hermes/cache/scratch/`: `account-draft-red.log` reproduces empty text instead of B after extracting the existing UI behavior unchanged; `account-draft-ack-red.log` catches acknowledgement clearing and stale read publication; `account-draft-recovery-green.log` records the first green; `account-draft-revision-red.log` catches five revised-draft variants plus remove clearing; `account-draft-final-tests.log` and `account-draft-ui-typecheck.log` hold the final passes. The full report is `nodyssey-account-recovery-fix.json`. No live mutations, commit or push were performed.
