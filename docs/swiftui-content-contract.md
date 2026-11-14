# Native content bridge contract

Implemented by `NativeBridge.kt`, `NativeContent.kt`, `NativeContentMapping.kt` in the iOS shell. This is the content section of the SwiftUI bridge contract; account/settings contracts have their own files. No new HTTP endpoints, Room tables, Swift persistence, or network-only feed implementations are introduced.

## ABI, lifetime, safety

```kotlin
NativeBridge.request(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest
NativeBridge.observe(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest
NativeRequest.cancel()
```

Arguments are a JSON **object**, including `{}` for no arguments. Completion runs on Main with `{"ok":true,"data":…}` or `{"ok":false,"error":{"code":"…","message":"Operation could not be completed."}}`. A known absent value/Unit is JSON `null`, NOT an unrecognized operation. Unknown operation/mode returns `UNKNOWN_OPERATION`. Request completes once; observation emits until canceled or terminal error. Cancel releases coroutine children, Room subscriptions and paging handle; canceled work does not deliver a completion/error. Swift must cancel on view/task teardown and discard obsolete UI task generations. No exception messages, server detail, cookie fingerprints, cookie/token values or stack traces cross the error ABI.

All calls initialize using the existing process-singleton `NodysseyApp.ensureContainer`. Reconcile cached session provenance before repository reads. Published session changes cancel old observation collectors, emit `data:null` immediately to invalidate Swift's last rendered value, and rebuild after reconciliation. **Every observation must accept this null invalidation**, including normally non-null feed/list/settings DTOs. Ordinary requests watch session changes, cancel in-flight work and suppress stale results; explicit session-changing account operations are exempt. Errors use `SESSION_CHANGED`; create a new observation after terminal error. Existing account-domain sign-out owns draft/offline/profile cleanup; content never clears drafts simply because a preview, load, or publish was attempted.

Content write operations reject an identical concurrent operation+canonical arguments with `BUSY`; ordering of JSON object keys does not defeat the guard. The guard releases on error/cancellation. This is **not server idempotency**: after an interrupted publish/send/vote/upload the server outcome may be unknown. Never automatically retry a mutation; verify server state before the user explicitly retries. Draft delete is separate and explicit, even after publish success. Different draft contents are distinct writes: Swift must serialize/debounce saves and flush them before leaving the editor.

Every side effect below is an explicit request from a user event. Observing a thread or message never marks it read, reacts, sends, spends, uploads, or deletes a draft. Use native confirmation for irreversible/spending actions. This bridge does not call live mutations in tests.

General argument rules: IDs are positive JSON integers (Swift `Int64`, never `Double`). JSON integer identity is preserved even above 2^53. Booleans must be JSON booleans, not strings. Enum values are **case-sensitive Kotlin `.name`**. `?` means optional/nullable. `page?` defaults to 1 and must be positive. `sort?` defaults to `LAST_REPLY`; alternative `POST_TIME`. Unspecified nullable output fields are present as JSON null, not invented defaults. Display timestamps/text retain existing repository units and formatting.

## Request operations

| Operation | Arguments | `data` / effect |
|---|---|---|
| `categories.get` | none | `Board[]` from Room |
| `categories.refresh` | none | existing repository `refreshIfNeeded`, then `Board[]`; repository's cache/fallback semantics apply |
| `feed.pageIndex` | categorySlug?, sort?, page? | `{index:Int?}` in the repository feed row order |
| `paging.access` | pagerId, index (zero-based global index) | null; sends Paging access hint, causing official prefetch/append/prepend as needed |
| `paging.refresh` | pagerId | null; official presenter refresh |
| `paging.retry` | pagerId | null; official presenter retry of failed loads, not arbitrary mutation retry |
| `search.local` | query | `FeedPost[]` from local Room search |
| `search.users` | query | `UserSearchResult[]` |
| `search.resolveMember` | name | `{uid:Int64?}` from exact shared resolver |
| `thread.get`, `thread.config` | postId | `ThreadSnapshot?` from Room; config is the same snapshot including parsed per-floor flags/reactions and collection state, not a guessed config endpoint |
| `thread.load` | postId, page?, extend?:Boolean=false | refresh/replaces window by default; `extend=true` delegates adjoining-page rules to repository; returns Room `ThreadSnapshot?` |
| `thread.status` | postId | `{isThreadFresh:Boolean,seenRepliesIfUnread:Int?,firstLoadedPage:Int?,lastLoadedPage:Int?}`; query BEFORE marking read |
| `thread.markRead` | postId | null; shared history/unread baseline write |
| `thread.position.get` | postId | `ReadingPosition?` |
| `thread.position.set` | postId, page?, floor?:String | null; actual shared reading-position store |
| `thread.react` | postId, commentId, action | null; action is `Upvote`, `ChickenLeg`, `Dislike`; repository writes confirmed reaction through Room |
| `thread.freeChickenLegs` | none | `{max:Int,used:Int,remaining:Int}?` |
| `thread.collect` | postId, collected:Boolean | null; confirmed bookmark toggle through shared repository |
| `vote.get` | voteId | `Vote` |
| `vote.submit` | voteId, itemIds:Int64[] | null; re-read `vote.get` after confirmed success |
| `vote.create` | title, multiple:Boolean, isPublic:Boolean, items:String[] | `{id:Int64}`; embed using the existing `nsapp://vote?id=N` syntax only after success |
| `vote.lock` | voteId, locked:Boolean | null |
| `vote.delete` | voteId | null |
| `vote.voters` | itemId, page? | `Int64[]`; repository provides no total |
| `editor.preview` | body:String | canonical `RichNode[]`, parsed on shared default dispatcher with `NodeSeekStickers::urlFor` |
| `editor.permissions` | selfRank?:Int | integer rank options from `PostPermission.options`, including 0 and 255 |
| `editor.post.publish` | title, body, boardSlug, permission:Int (0…255) | `{postId:Int64?}`; null id means accepted but unresolved, NOT failure/retry |
| `editor.comment.publish` | postId, body, quotedFloor?:Int | `{floor:Int?}`; shared repository accepts `quotedFloor` but wire body is the caller's Markdown (include quote/mention text in body); null floor is accepted but unknown |
| `editor.edit.load` | postId, commentId, page?, isOpeningPost:Boolean | `PostEditContent`; shared source loader, not reconstruction from rendered rich nodes |
| `editor.edit.save` | postId, commentId, page?, isOpeningPost:Boolean, title, body, permission:Int | null; actual `PostEditor.save`, including best-effort shared thread reload; title/permission still required for complete DTO even for a comment |
| `editor.image.upload` | id:String (attachment identity), source:String (`file://` picker URL), name:String | `{id,remoteUrl:String,markdown:String}` through existing iOS preparer/image-host uploader; no remote-URL fetch accepted |
| `draft.post.get` | none | `PostDraft?` |
| `draft.post.save` | title, body, boardSlug?, boardTitle?, permission:Int | null; repository stamps `savedAtMillis`, observes/read back to obtain it |
| `draft.post.delete` | none | null |
| `draft.comment.get` | postId | `CommentDraft?` |
| `draft.comment.save` | postId, body, replyToFloor?:Int, replyToAuthor?, replyToText? | null; preserves reply context, repository stamps saved time |
| `draft.comment.delete` | postId | null |
| `notifications.list` | category?:`REPLIES` or `MENTIONS` | `ForumNotification[]`; omit category for repository's deduplicated interactions |
| `notifications.counts` | none | current `NotificationCounts` (no network refresh) |
| `notifications.refresh` | none | refreshed `NotificationCounts`; invalidates active notification-list observers |
| `notifications.read` | sources:`NotificationSource[]` | null; pass the displayed row's **whole sources array** so merged reply+mention clear both; null viewedId is retained, never synthesized |
| `notifications.readAll` | category:`REPLIES` or `MENTIONS` | null; call each category explicitly for combined interactions |
| `messages.list` | none | `MessageConversation[]`, including system conversation |
| `messages.thread` | uid | `MessageThread`, no implicit read mutation |
| `messages.refresh` | none | null; invalidates active message-list/thread observers; no stored duplicate message cache |
| `messages.read` | messageIds:Int64[] | null; use `MessageThread.unreadIds`, not display ids |
| `messages.readAll` | none | null |
| `messages.send` | uid, content, markdown:Boolean | accepted `DirectMessage?`; null is repository-confirmed success without a message DTO, never a fabricated bubble; invalidates message observers |

`MESSAGES` is not accepted by notification list/read operations: use messages operations. The underlying notification repository would silently return an empty list/no-op for that category; the bridge deliberately rejects it.

## Observe operations

| Operation | Arguments | emissions |
|---|---|---|
| `feed` | pagerId:String, categorySlug?, sort?, page? | `PagingSnapshot` |
| `search.feed` | pagerId:String, query, categorySlug?, sort? | `PagingSnapshot`; uses actual `PostRepository.searchFeed` Pager/Room SSOT |
| `search.local` | query | `FeedPost[]` on Room changes |
| `categories` | none | `Board[]` on Room changes; request refresh explicitly |
| `thread`, `thread.config` | postId | `ThreadSnapshot?` on Room changes, including null after cache removal |
| `draft.post` | none | `PostDraft?` from existing DataStore |
| `draft.comment` | postId | `CommentDraft?` from existing DataStore |
| `notifications.counts` | none | `NotificationCounts` shared state |
| `notifications.list` | category? | initial repository fetch and refetch after explicit notification refresh/read/readAll |
| `messages.list` | none | initial repository fetch and refetch after explicit messages refresh/read/readAll/send |
| `messages.thread` | uid | same invalidation lifecycle, `MessageThread` |

Message/notification repositories have no Room list Flow or server push stream. Their observers are cancellable **invalidation-driven reads**, not fake realtime data and not autonomous polling. External changes become visible on the next explicit refresh. No mutation is exposed as an observation. Errors terminate the observation; UI must present failure and explicitly re-subscribe/retry.

### PagingSnapshot

```text
{pagerId:String, items:FeedPost[], placeholdersBefore:Int, placeholdersAfter:Int,
 itemCount:Int, page:Int, totalPages:Int?, refresh:LoadState, append:LoadState, prepend:LoadState}
```

Uses pinned Paging **3.5.1** `PagingDataPresenter`, `PagingDataEvent`, `snapshot`, `loadStateFlow`, `collectFrom`, `get`, `refresh`, `retry`. Pinned sources were fetched from Google's `paging-common/3.5.1` source artifact and inspected. No Android-only differ, `asSnapshot` testing API, invented cursors, second persistent cache, or network bypass is used.

`items` contains the loaded window only. Its local index `i` corresponds to global index `placeholdersBefore+i`. `itemCount = placeholdersBefore + items.size + placeholdersAfter`; placeholders are not fabricated post rows. Report visible **global** indices using `paging.access` so Paging loads more. Use `summary.postId` for stable row identity, never list index. The `page` is the requested starting page, NOT the current scroll position; each FeedPost carries its actual nullable page. Feed total is the existing `feedTotalPages` metadata (repository starts at 1); search has no total API and returns null. Empty loaded pages expose terminal NotLoading, not an endless spinner.

Keep a unique `pagerId` per live observation. Duplicate id fails `PAGER_IN_USE`; missing/closed id fails `PAGER_CLOSED`; out-of-range access fails `INVALID_ARGUMENT`. Cancel observation to release handle. Re-subscribe for a different board, sort, search or starting page. Events are conflated to the latest complete presenter snapshot; no append-list merging is needed in Swift.

LoadState: `{status:"Idle"}`, `{status:"Loading"}`, `{status:"NotLoading",endOfPaginationReached:Boolean}` or `{status:"Error",error:{code,message}}`. Errors are sanitized by the same core mapper. Refresh success alone does not mean append has reached the end.

## DTO field inventory

Types use Kotlin field names; `?` below denotes JSON null, arrays are JSON arrays. IDs/counts/timestamps are integers; other non-Boolean scalars below are strings unless explicitly stated.

- **Board**: slug?, title, description?, adminOnly:Boolean.
- **FeedPost**: summary:PostSummary, isRead:Boolean, newCommentCount:Int, page:Int?.
- **PostSummary**: postId:Int64, title, authorName, authorUid:Int64?, avatarUrl?, categoryTitle?, categorySlug?, viewCount:Int?, commentCount:Int?, lastActiveText?, lastActiveTitle?, lastCommenterName?, isPinned:Boolean, isLocked:Boolean, isAwarded:Boolean, lockLevel:Int?, isBlocked:Boolean.
- **ThreadSnapshot**: postId:Int64, title, body:PostContent?, comments:PostContent[], firstLoadedPage:Int, lastLoadedPage:Int, totalPages:Int, cachedAtMillis:Int64, commentPages:Int[], collected:Boolean?, collectionCount:Int?, isAwarded:Boolean?, hasNextPage:Boolean.
- **PostContent**: commentId:Int64?, floor?, authorName, authorUid:Int64?, avatarUrl?, isOriginalPoster:Boolean, badges:String[], createdAtText?, createdAtTitle?, categoryTitle?, nodes:RichNode[], isEdited:Boolean, editedAtText?, editedAtTitle?, signatureNodes:RichNode[], reactions:PostReactions?, isBlocked:Boolean, isMine:Boolean.
- **PostReactions**: likeCount:Int, dislikeCount:Int, upvoteCount:Int, liked:Boolean, disliked:Boolean, upvoted:Boolean.
- **ReadingPosition**: page:Int, floor:String?.
- **UserSearchResult**: uid:Int64, name, avatarUrl?, level:Int?, bio?, joinedText?, topicCount:Int?, commentCount:Int?.
- **Vote**: id:Int64, title, ownerUid:Int64, isPublic:Boolean, locked:Boolean, multiple:Boolean, items:VoteItem[]. **VoteItem**: itemId:Int64, text, voted:Boolean, count:Int?, voters:Int64[]. Unknown counts remain null before voting.
- **PostDraft**: title, body, boardSlug?, boardTitle?, permission:Int, savedAtMillis:Int64. **CommentDraft**: body, replyToFloor:Int?, replyToAuthor?, replyToText?, savedAtMillis:Int64. **PostEditContent**: title, permission:Int, body. Permission is shared rank wire value, not an invented enum.
- **NotificationCounts**: replies:Int, mentions:Int, messages:Int, overlap:Int, interactions:Int, all:Int. Derived totals are repository-calculated, not recomputed in Swift.
- **NotificationSource**: category (`REPLIES`, `MENTIONS`, `MESSAGES`), viewedId:Int64?, isUnread:Boolean.
- **ForumNotification**: id:String, sources:NotificationSource[], commentId:Int64?, postId:Int64?, floor?, actorUid:Int64?, actorName, avatarUrl?, threadTitle?, createdAtMillis:Int64?, createdAtText?, isUnread:Boolean, isReply:Boolean, isMention:Boolean.
- **MessageConversation**: uid:Int64, userName, avatarUrl?, snippet:PreviewPart[], isSnippetMine:Boolean, updatedAtMillis:Int64?, updatedAtText?, unreadCount:Int, isSystem:Boolean.
- **PreviewPart** (NOT RichNode): `{type:"Text",text:String}` or `{type:"Placeholder",kind:"IMAGE"|"STICKER"|"CODE"|"TABLE"|"VOTE"|"PAYMENT"}`.
- **DirectMessage**: id:String, isMine:Boolean, content:String, isMarkdown:Boolean, sentAtMillis:Int64?, sentAtText?. Parse Markdown via `editor.preview` when `isMarkdown`; render plain text otherwise.
- **MessageThread**: uid:Int64, userName, avatarUrl?, level:Int?, messages:DirectMessage[] (oldest first), unreadIds:Int64[], createdAt:String?.
- **RichNode** and nested InlineNode: canonical tagged kotlinx.serialization JSON from `richtext/.../RichNode.kt`, using existing `@SerialName` discriminator strings and `Json { encodeDefaults=true }`. No renamed discriminator, HTML-to-Swift shortcut or hand-written reduced tree. Swift must support the full shared tree.

## Errors and honest verification boundaries

Codes: `UNKNOWN_OPERATION`, `INVALID_ARGUMENT`, `BUSY`, `SESSION_CHANGED`, `PAGER_CLOSED`, `PAGER_IN_USE`, `CHALLENGE`, `LOGIN_REQUIRED`, `SESSION_UNRECOGNISED`, `LEVEL_REQUIRED`, `PRIVATE_POST`, `QUERY_TOO_SHORT`, `RATE_LIMITED`, `HTTP`, `NETWORK`, `UNPARSABLE`, `UNSUPPORTED`, `REFUSED`, `INTERNAL`, `IMAGE_HOST_NOT_CONFIGURED`, `IMAGE_HOST_INVALID_KEY`, `IMAGE_HOST_REJECTED`, `IMAGE_HOST_CHALLENGE`, `IMAGE_HOST_HTTP`, `INSECURE_LINK`. Message text is deliberately non-diagnostic; native UI localizes the error code. Challenge URLs are not echoed from arbitrary exceptions; authentication/challenge navigation is the platform/account owner's responsibility.

Focused iosTest source covers late-callback suppression, idempotent cancel, cancellation propagation, secret-free errors, strict numeric/Boolean input validation, high-bit identity, canonical RichNode roundtrip, notification source identity, invalid read position, in-flight mutation dedup/release, logout/account stale-response rejection, and empty Paging terminal-state/handle cleanup. Initial tests were written before implementation; `./gradlew :iosapp:iosSimulatorArm64Test --offline` could not start because the host had no Java. A portable Azul **JRE 21** was then downloaded into scratch (no build changes). Using cached Kotlin **2.4.20**, actual `shared-jvm.jar` / `ui-jvm.jar` / `richtext-jvm.jar`, Paging **3.5.1** and coroutines **1.11.0**, all three owned production files plus iosTest sources compiled on JVM and **JUnit passed 12 tests**. This harness substitutes only the unavailable iOS shell constructor and other domains' dispatch link symbols; it does not stub the tested Paging, serialization, model, cancellation or gate behavior. It never initializes a real container or sends network mutations. Cached ktlint **1.8.0**, with the repository's exact rule overrides, formatted and checked only these six owned Kotlin files.

This is a JVM contract check, **not native compilation**. The subsequent real `:iosapp:compileKotlinIosSimulatorArm64 --offline --no-daemon` invocation with that JRE reached Gradle but failed configuring build-logic because no JDK 21 compiler/toolchain is installed. No behavioral pre-implementation RED, native linker, simulator/device or server mutation success is claimed. Parent owns full native dependencies/build/entrypoint integration and macOS/Xcode CI.

Remaining explicit boundaries: upload is cancellable one-shot without progress emissions; no realtime server push exists; server-idempotency and transport-indeterminate write outcomes remain unsolved by the upstream APIs. Full session-change/sign-out/Room race integration and draft-preservation integration require the real container/native test environment. Kotlin/Native/Xcode build and frontend route integration are acceptance gates, not implied by source completion.
