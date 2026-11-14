# Reaction reconciliation contract (CL-01-R1/R2)

**Integration status: repository and native dispatch seam implemented; session-boundary and Apple gates remain.** `PostRepository.reconcileThreadReactions` and `ThreadReactionRead` now exist, and the NativeContent/NativeContentMapping patch is applied through `graph.postRepository`. Parent reran the complete real Room regression: **12 scenario groups passed**. Implementer ran the complete repository-to-Swift replay: **27 functions / 45 expanded cases passed, zero skips**; Independent full-path re-review passed (`nodyssey-reaction-final-rereview.json`), including its own 12 Room groups and 27-function / 45-case Swift replay with zero skips. CL-01-R1/R2 are resolved at scoped source/behavior level. Normal loads cannot unlock the Swift latch. Review found the implemented graph seam and outer `privateBoundary.protect` guard, with no missing delegation. Full native session-boundary execution and Apple linkage remain unaccepted; no raw-remote bypass or Apple runtime pass is claimed. The aggregate Content typecheck runner separately needs actual Sharing sources included; its temporary staging workaround is not repository acceptance.

## Shared seam requested from PostRepository owner

Add `suspend fun reconcileThreadReactions(postId: Long, page: Int): ThreadReactionRead` to `PostRepository` and its production/wrapped implementation. Default unsupported implementations must throw, never fabricate coverage.

`data class ThreadReactionRead(val postId: Long, val page: Int, val commentIds: List<Long>, val openingCommentId: Long?)`

The implementation must perform a **new network-only** `remote.loadDetail(postId, page)`, persist through the existing DAO (extension semantics are acceptable), then return coverage derived **only from that network response**: only identities whose `PostContent.reactions != null` in `detail.comments`, and `detail.body?.commentId` only when its reactions are nonnull. An HTML page without account reaction config is NOT authoritative reaction coverage. `PostContent.commentId` is nullable: omit null IDs. No offline fallback, TTL, merged snapshot, or existing opening body may contribute to coverage. Validate returned post/page identity; if load, cancellation, boundary, or persistence fails, no success/coverage escapes. Preserve normal refreshThread/extendThread offline behavior and Android callers.

Use the existing graph's session-bound repository. Do not introduce a raw alternate remote bypass, a second graph, or Swift-generated provenance. Shared owner must ensure any session-bound wrappers delegate this additive method under their existing session barrier.

## Native bridge and Swift consumer (content owner)

New read-only operation `thread.reconcileReactions` arguments `{postId, page}` calls the shared seam through `graph.postRepository`. Result `{postId,page,commentIds,openingCommentId}` is a dedicated network-read receipt, not thread snapshot metadata. Native mapping adds no inferred provenance.

Swift stores the uncertain mutation's post/comment/page/opening identity, session generation, and a new reconciliation token. Ordinary `thread.load` can never unlock reactions, even if it succeeds or includes the uncertain comment. Explicit Reload while blocked uses the dedicated operation directed at the affected page (opening body uses page 1). Receipt must match post/page and affected comment identity, unchanged generation and token, and a noncancelled read begun after the uncertain mutation. An absent/deleted/moved comment stays blocked; no retry is inferred from absence. Unrelated loads and commands remain usable without clearing the latch.

## Verification required

Behavioral RED→GREEN for successful cached/offline `thread.load`, unrelated merged page and nonextend loads, retained opening body, matching/mismatching explicit receipts, cancellation, preexisting in-flight load, generation/identity changes. Real OfflineFirstPostRepository with temporary Room must prove normal offline fallback still works, dedicated network read fails without fallback, merged pages do not contribute coverage, opening body retained in Room does not contribute coverage, and relevant fresh response permits matching reconciliation. No live spending.

This document publishes the requested seam before shared-owner coordination. Implementation and exact execution evidence will be recorded in the handoff JSON; until then it is a requested contract, not a claim of implemented backend support.
