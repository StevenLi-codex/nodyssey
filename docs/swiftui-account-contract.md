# Native account/community contract

Internal entrypoints: `NativeContext.accountRequest(operation, args): JsonElement?` and `accountObserve(operation, args): Flow<JsonElement>?`. Null return is **only** unrecognized operation; absent known values use JSON null. NativeBridge supplies envelopes, sanitized errors, cancellation, Main dispatch and initial session/cache reconciliation. All IDs are JSON integers, never floating-point conversions. Nullable model fields remain JSON null. Mutations are single calls without bridge retries; a Unit result is `{}` (acknowledgement, not a fabricated refreshed value).

## Frontend operation inventory

Arguments marked `?` may be omitted/null. Page defaults to 1; positive IDs/page/amount are required unless stated otherwise. Destructive/spending/security writes explicitly require `confirmed: true`, set only after a native confirmation dialog. Never persist/log request bodies containing passwords, verification tokens, OTP codes, enrolment URI or challenge handles. Credentials and OTP are transient request input only; raw `otpSession` stays bridge-held.

| Request | Arguments | Data |
|---|---|---|
| `session.snapshot`, `session.sync` | none | Session |
| `session.signIn` | account, password, verificationToken | SignIn |
| `session.verifyTwoFactor` | challengeId, code (six ASCII digits) | SignIn |
| `session.cancelSignIn` | none | {} |
| `session.signOut` | confirmed | Session |
| `profile.self` | refresh?: boolean | UserProfile |
| `profile.user` | uid | UserProfile |
| `space.topics`, `space.comments` | uid, page? | SpacePage |
| `space.collections`, `bookmarks.list` | page? | SpacePage<SpacePost> (remote page, not offline library) |
| `bookmarks.snapshot` | none | CollectedPostMeta[] (local persisted collection; also observable) |
| `bookmarks.refresh` | none | {items:CollectedPostMeta[],truncated:boolean} |
| `social.following`, `social.followers` | none | FollowUser[] |
| `social.follow`, `social.unfollow` | uid | {} |
| `account.blockedUsers` | none | BlockedUser[] |
| `social.block` | name, confirmed | {} |
| `social.unblock` | uid, confirmed | {} |
| `history.list` | none | ReadHistoryEntry[] |
| `history.remove` | postId, confirmed | {undoId} |
| `history.restore` | undoId | {} |
| `history.clear` | confirmed | {} |
| `tracked.list` | none | TrackedThread[] |
| `assets.growth` | none | GrowthSnapshot |
| `assets.credit` | page? | {items:CreditEntry[],page,totalPages?,hasNextPage} |
| `assets.stardust` | memberId?, beforeId? | {items:StardustEntry[],cursor?,hasMore} |
| `assets.recipient` | recipientUid | {name:string?} |
| `assets.transfer` | recipientUid, amount, refId (>=0), onetime:boolean, confirmed | {} |
| `assets.receipts` | memberId, refId (>=0), peerId? | StardustEntry[] |
| `assets.receiveCode` | amount, refId (>=0), description, onetime:boolean | {memberId,refId,marker} |
| `attendance.status` | none | AttendanceStatus |
| `attendance.sign` | mode: RANDOM or FIXED_FIVE, confirmed | AttendanceResult |
| `attendance.board` | page? | AttendanceBoardEntry[] |
| `community.memberCount` | none | {memberCount:integer} |
| `community.award` | page? | {items:PostSummary[],page,totalPages} |
| `community.ruling` | page? | {items:RulingRecord[],page,totalPages} |
| `community.lucky` | postId,drawAtMillis,prizeCount,startFloor (>=0),dedupeFloors:boolean | {url} |
| `community.invite` | none | {chickenCount?,url,purchaseRequiresWeb:true} |
| `account.profileFields` | none | AccountProfileFields |
| `account.saveProfileFields` | bio,signature,readme | {} |
| `account.uploadAvatar` | base64 (<=8,388,608 chars; decoded 1–6,291,456 bytes),mimeType (`image/jpeg`, `image/png`, `image/gif`),confirmed | {} |
| `account.changePassword` | currentPassword,newPassword,confirmed | {} |
| `account.twoFactor` | none | {enabled} |
| `account.beginTwoFactor` | password,confirmed | {uri} (transient authenticator enrolment) |
| `account.contact` | none | AccountContact |
| `account.telegram` | none | TelegramBinding |
| `account.unbindTelegram` | confirmed | {} |
| `account.preferences` | none | RemoteAccountPreferences |
| `account.holidayTheme` | enabled:boolean | {} |
| `account.homeBoard` | slug,hidden:boolean | {} |
| `reports.list` | none | ReportCompareEntry[] |
| `reports.compare` | entries:ReportCompareEntry[] (2–3 distinct existing entries) | ReportComparison |

Observe: `session.state` → Session; `profile.self` → UserProfile/null scoped to active session; `attendance.status` → AttendanceStatus/null scoped to signed-in UID; `history.list`, `tracked.list`, `reports.list` → same arrays as request. Each observation is cancellable. On session changes profile observation switches provenance before reading cached profile; logout emits null. Title keyword/block-regex/alert settings and all `notes.*` belong to **NativeSettings**, not this domain. `tracked.get/observe/add/remove` and `reports.get/observe/add/remove` also belong to NativeSettings (canonical mutations and response schema); account exposes only the `tracked.list` / `reports.list` read aliases and `reports.compare`. This prevents conflicting handlers or response types. Use complete report entry JSON returned by the basket for compare/remove, never a list index: indices become stale when the basket changes. Content agent owns post collection toggles and adding reports from thread content; this domain reads existing server collections and the comparison basket.

## DTOs

All DTOs preserve public Kotlin model field names, except page row lists consistently use `items`. Session: `{isSignedIn,hasClearance,generation}`; fingerprint is intentionally not exported. SignIn: `{status:"SIGNED",session:Session}`, `{status:"TWO_FACTOR_REQUIRED",challengeId,account}`, or `{status:"REFUSED",reason}`; untrusted server detail is not echoed. A challenge is single active, memory-only, invalidated on new sign-in/cancel/signout/session change and has a short expiry. It is not a credential-storage API.

UserProfile: uid,name,avatarUrl,rank?,createdAt?,chickenCount?,starCount?,streakDays?,bio?,readme?,topicCount?,commentCount?,followed?. SpacePage: `{items,page,hasNextPage}`. SpacePost: postId,title,categoryTitle?,categorySlug?,authorName?,commentCount?,viewCount?,createdAtText?,permission (integer rank). SpaceComment: postId,commentId?,postTitle?,excerpt,createdAtText?,floor?. FollowUser/BlockedUser: uid,name,avatarUrl?.

GrowthSnapshot: level?,chickenCount?,starCount?,levelSpan?,postQuota,commentQuota,attendanceQuota,feedingQuota. DailyQuota: `{used?,total?}`. CreditEntry: change,balanceAfter?,reason,createdAtMillis?. StardustEntry: id,type (enum name),rawType?,diff,balanceAfter?,peerUid?,commentId?,refId?,createdAtMillis?. AttendanceStatus: uid,date (ISO date),hasSignedIn,gain?; AttendanceResult: gain?,message?; AttendanceBoardEntry: uid?,name,gain?,timeText?.

AccountProfileFields: bio,signature,readme. AccountContact: email,emailVerified. TelegramBinding: bound,displayName?,avatarUrl?. RemoteAccountPreferences: holidayTheme,hiddenBoards (string array).

ReadHistoryEntry: postId,title?,authorName?,authorUid?,categoryTitle?,commentCount?,lastReadAtMillis,readingPosition?. TrackedThread: postId,title,lastKnownCount,authorName?,categoryTitle?,categorySlug?. RulingRecord: id,targetName,targetUid?,target (enum),postId?,floor?,reason?,actions,moderatorName?,createdAtMillis?,kind (enum); actions are tagged objects with `type` and the actual subtype fields.

## Library and mutation lifecycle

`bookmarks.snapshot` is the offline-first screen source. Observe it before requesting `bookmarks.refresh`; refresh walks at most 20 server pages, stops on empty/terminal pages, deduplicates by integer postId, then stores the collection and updates existing OfflineLibrary reply counts. On a failed/cancelled page walk the old collection remains intact. `truncated:true` means counts represent only the bounded walk, not the entire remote collection. `bookmarks.list` is deliberately only a remote-page alias for space collections. Offline state/download/cancel/settings/estimation are NativeSettings `offline.*`; collection toggles belong to NativeContent, and the Swift UI must preserve per-item success/failure when bulk-deleting/undoing. Never count only the currently visible rows as all selected rows.

History removal returns a bridge-held `undoId`; `history.restore` restores the exact repository snapshot including readingPosition, not data supplied by Swift. The receipt is single-use, expires after five minutes, is bounded to 20 outstanding removals, and is invalid across session changes/clear/signout. A failed restore does not consume it. Clear has no undo.

Account writes/spending share a fail-fast in-flight gate (not a retry queue). Disable controls while pending; a second overlapping write is rejected as `INVALID_ARGUMENT` rather than queued. This does not claim server idempotency: after an uncertain network result, refresh the authoritative ledger/status before offering another confirmation. Mutations never automatically repeat. Remote success is not followed by a profile reload inside the same call: after a profile/avatar save request `profile.self` with `refresh:true` separately; after follow/block refresh user space/feed separately. A failed refresh must not be labelled a failed save.

Signout invokes the existing `AccountSignOut` orchestration (post/profile/offline/drafts/notification baseline cleanup before cookie clearing and signed-out publication), never a cookie-only shortcut. Two-factor challenge and history-undo handles are transient and invalidated by full session identity (fingerprint stays internal). End the auth screen with `session.cancelSignIn`. Do not call `session.sync` between receiving a two-factor challenge and submitting it: explicit browser sync cancels the pending native auth lifecycle.

## Additional DTO details

CollectedPostMeta: postId,title?,categoryTitle?,categorySlug?,authorName?,avatarUrl?,resolvedAvatarUrl?,authorUid?,commentCount?,createdAtText?. LevelSpan: barRank,floor,next. ReadingPosition: page,floor?. PostSummary: postId,title,authorName,authorUid?,avatarUrl?,categoryTitle?,categorySlug?,viewCount?,commentCount?,lastActiveText?,lastActiveTitle?,lastCommenterName?,isPinned,isLocked,isAwarded,lockLevel?,isBlocked. Award pages also expose hasNextPage.

ReportCompareEntry uses the **existing** serializer: `{report,postId?,threadTitle?,floor?}`; QualityReport is `{title,target?,generatedAt?,scriptVersion?,sections:[{title,blocks}],footnotes:[string]}`. Block `type` tags are `field` (label,values), `badges` (label,items), `table` (columns,rows), `note` (text). Values/badges use `{text,tone}`; tone names are `Neutral/Good/Warn/Bad`. Table rows have label,cells. ReportComparison: `{reportCount,sections:[{title,rows:[{label,cells}]}]}`; cells are an ordered array of value arrays or null for missing data. No numeric identity is inferred from a report title or index.

Ruling action tags and fields: Coin(diff), Stardust(diff), Title(title), Move(boardSlug), ReadRank(rank), Lock(locked), Award(award), Hide(hidden,wholeUser), Pin(pinned), Suspend(days?). Enum tags use exact spelling shown; `days:null` is lifting a suspension, not zero days.

## Honest platform boundaries

The existing repositories have no native email-change, Telegram-bind, invite-purchase or TOTP-disable/complete endpoint. These remain explicit site-owned account/authentication flows (not generic native route fallbacks); do not fake a successful mutation. Invite read never purchases. Lucky and receive-code generation are local pure shared-domain operations and never publish anything. WKWebView cookie synchronization is supplied by the platform adapter before `session.sync`; no cookie or token is exported through DTOs. No live spending/posting is used for validation.

## Verification evidence and remaining gates

- Implemented 55 request operation names; programmatic comparison found no undocumented request and no overlap with NativeContent/NativeSettings handlers.
- Built real `:shared:jvmJar`; compiled both account production files unchanged against that artifact and the pinned serialization/coroutine/datetime libraries, using a compile-only iOS container/context signature shim. All repository method and DTO field references typechecked. The shim has throwing getters, not fake repository behavior, and is scratch-only.
- Executed all 11 `NativeAccountTest` tests on JVM/JUnit: strict confirmation/types/Int64 preservation, sensitive session-field omission, challenge session/expiry/replacement, history undo isolation/single-use, collection paging/dedup/bounds/cancellation, concurrent mutation rejection and lock release, attendance account/date isolation.
- Scoped Spotless formatting ran against only the two owned production files and owned test file.
- `:iosapp:iosSimulatorArm64Test` was attempted but native compile/link/test were **SKIPPED** on Linux ARM. This is not an iOS test pass. Apple compilation/export/header integration, real network/authentication, native UI confirmation/navigation and simulator/device execution remain parent CI/platform gates.
