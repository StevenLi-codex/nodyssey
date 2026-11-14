package io.github.nodyssey.ios.native

import io.github.nodyssey.data.Board
import io.github.nodyssey.data.DirectMessage
import io.github.nodyssey.data.FeedPost
import io.github.nodyssey.data.ForumNotification
import io.github.nodyssey.data.FreeChickenLegs
import io.github.nodyssey.data.MessageConversation
import io.github.nodyssey.data.MessageThread
import io.github.nodyssey.data.NotificationCounts
import io.github.nodyssey.data.NotificationSource
import io.github.nodyssey.data.PreviewPart
import io.github.nodyssey.data.ReadingPosition
import io.github.nodyssey.data.ThreadReactionRead
import io.github.nodyssey.data.UserSearchResult
import io.github.nodyssey.data.composer.CommentDraft
import io.github.nodyssey.data.composer.PostDraft
import io.github.nodyssey.data.composer.PostEditContent
import io.github.nodyssey.model.PostContent
import io.github.nodyssey.model.PostReactions
import io.github.nodyssey.model.PostSummary
import io.github.nodyssey.model.ThreadSnapshot
import io.github.nodyssey.model.Vote
import io.github.nodyssey.model.VoteItem
import io.github.plaza.core.richtext.RichNode
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray

private val nativeRichJson = Json { encodeDefaults = true }
internal fun nativeRichNodes(nodes: List<RichNode>): JsonArray =
    nativeRichJson.encodeToJsonElement(ListSerializer(RichNode.serializer()), nodes).jsonArray

/** Explicit scalar-only DTO builder: never reflect/serialize an arbitrary repository object. */
internal fun nativeContentObject(vararg fields: Pair<String, Any?>): JsonObject =
    JsonObject(fields.associate { (key, value) -> key to nativeContentScalar(value) })

private fun nativeContentScalar(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    else -> error("Unsupported native DTO value")
}
internal fun <T> nativeContentArray(values: List<T>, map: (T) -> JsonElement): JsonArray = JsonArray(values.map(map))
internal fun nativeContentStrings(values: List<String>): JsonArray = JsonArray(values.map(::JsonPrimitive))
internal fun nativeContentLongs(values: List<Long>): JsonArray = JsonArray(values.map(::JsonPrimitive))

internal fun nativeContentJson(v: Board): JsonObject = nativeContentObject(
    "slug" to v.slug,
    "title" to v.title,
    "description" to v.description,
    "adminOnly" to v.adminOnly,
)
internal fun nativeContentJson(v: PostSummary): JsonObject = nativeContentObject(
    "postId" to v.postId, "title" to v.title, "authorName" to v.authorName, "authorUid" to v.authorUid,
    "avatarUrl" to v.avatarUrl, "categoryTitle" to v.categoryTitle, "categorySlug" to v.categorySlug,
    "viewCount" to v.viewCount, "commentCount" to v.commentCount, "lastActiveText" to v.lastActiveText,
    "lastActiveTitle" to v.lastActiveTitle, "lastCommenterName" to v.lastCommenterName,
    "isPinned" to v.isPinned, "isLocked" to v.isLocked, "isAwarded" to v.isAwarded,
    "lockLevel" to v.lockLevel, "isBlocked" to v.isBlocked,
)
internal fun nativeContentJson(v: FeedPost): JsonObject = nativeContentObject(
    "summary" to nativeContentJson(v.summary),
    "isRead" to v.isRead,
    "newCommentCount" to v.newCommentCount,
    "page" to v.page,
)
internal fun nativeContentJson(v: PostReactions): JsonObject = nativeContentObject(
    "likeCount" to v.likeCount,
    "dislikeCount" to v.dislikeCount,
    "upvoteCount" to v.upvoteCount,
    "liked" to v.liked,
    "disliked" to v.disliked,
    "upvoted" to v.upvoted,
)
internal fun nativeContentJson(v: PostContent): JsonObject = nativeContentObject(
    "commentId" to v.commentId, "floor" to v.floor, "authorName" to v.authorName, "authorUid" to v.authorUid,
    "avatarUrl" to v.avatarUrl, "isOriginalPoster" to v.isOriginalPoster, "badges" to nativeContentStrings(v.badges),
    "createdAtText" to v.createdAtText, "createdAtTitle" to v.createdAtTitle, "categoryTitle" to v.categoryTitle,
    "nodes" to nativeRichNodes(v.nodes), "isEdited" to v.isEdited, "editedAtText" to v.editedAtText,
    "editedAtTitle" to v.editedAtTitle, "signatureNodes" to nativeRichNodes(v.signatureNodes),
    "reactions" to v.reactions?.let(::nativeContentJson), "isBlocked" to v.isBlocked, "isMine" to v.isMine,
)
internal fun nativeContentJson(v: ThreadReactionRead): JsonObject = nativeContentObject(
    "postId" to v.postId, "page" to v.page,
    "commentIds" to nativeContentLongs(v.commentIds), "openingCommentId" to v.openingCommentId,
)
internal fun nativeContentJson(v: ThreadSnapshot): JsonObject = nativeContentObject(
    "postId" to v.postId, "title" to v.title, "body" to v.body?.let(::nativeContentJson),
    "comments" to nativeContentArray(v.comments, ::nativeContentJson),
    "firstLoadedPage" to v.firstLoadedPage, "lastLoadedPage" to v.lastLoadedPage, "totalPages" to v.totalPages,
    "cachedAtMillis" to v.cachedAtMillis, "commentPages" to JsonArray(v.commentPages.map(::JsonPrimitive)),
    "collected" to v.collected, "collectionCount" to v.collectionCount, "isAwarded" to v.isAwarded,
    "hasNextPage" to v.hasNextPage,
)
internal fun nativeContentJson(v: ReadingPosition): JsonObject = nativeContentObject("page" to v.page, "floor" to v.floor)
internal fun nativeContentJson(v: FreeChickenLegs): JsonObject = nativeContentObject("max" to v.max, "used" to v.used, "remaining" to v.remaining)
internal fun nativeContentJson(v: UserSearchResult): JsonObject = nativeContentObject(
    "uid" to v.uid,
    "name" to v.name,
    "avatarUrl" to v.avatarUrl,
    "level" to v.level,
    "bio" to v.bio,
    "joinedText" to v.joinedText,
    "topicCount" to v.topicCount,
    "commentCount" to v.commentCount,
)
internal fun nativeContentJson(v: VoteItem): JsonObject = nativeContentObject(
    "itemId" to v.itemId,
    "text" to v.text,
    "voted" to v.voted,
    "count" to v.count,
    "voters" to nativeContentLongs(v.voters),
)
internal fun nativeContentJson(v: Vote): JsonObject = nativeContentObject(
    "id" to v.id,
    "title" to v.title,
    "ownerUid" to v.ownerUid,
    "isPublic" to v.isPublic,
    "locked" to v.locked,
    "multiple" to v.multiple,
    "items" to nativeContentArray(v.items, ::nativeContentJson),
)
internal fun nativeContentJson(v: PostDraft): JsonObject = nativeContentObject(
    "title" to v.title,
    "body" to v.body,
    "boardSlug" to v.boardSlug,
    "boardTitle" to v.boardTitle,
    "permission" to v.permission.wireValue,
    "savedAtMillis" to v.savedAtMillis,
)
internal fun nativeContentJson(v: CommentDraft): JsonObject = nativeContentObject(
    "body" to v.body,
    "replyToFloor" to v.replyToFloor,
    "replyToAuthor" to v.replyToAuthor,
    "replyToText" to v.replyToText,
    "savedAtMillis" to v.savedAtMillis,
)
internal fun nativeContentJson(v: PostEditContent): JsonObject = nativeContentObject(
    "title" to v.title,
    "permission" to v.permission.wireValue,
    "body" to v.body,
)
internal fun nativeContentJson(v: NotificationCounts): JsonObject = nativeContentObject(
    "replies" to v.replies,
    "mentions" to v.mentions,
    "messages" to v.messages,
    "overlap" to v.overlap,
    "interactions" to v.interactions,
    "all" to v.all,
)
internal fun nativeContentJson(v: NotificationSource): JsonObject = nativeContentObject(
    "category" to v.category.name,
    "viewedId" to v.viewedId,
    "isUnread" to v.isUnread,
)
internal fun nativeContentJson(v: ForumNotification): JsonObject = nativeContentObject(
    "id" to v.id, "sources" to nativeContentArray(v.sources, ::nativeContentJson),
    "commentId" to v.commentId, "postId" to v.postId, "floor" to v.floor, "actorUid" to v.actorUid,
    "actorName" to v.actorName, "avatarUrl" to v.avatarUrl, "threadTitle" to v.threadTitle,
    "createdAtMillis" to v.createdAtMillis, "createdAtText" to v.createdAtText,
    "isUnread" to v.isUnread, "isReply" to v.isReply, "isMention" to v.isMention,
)
internal fun nativeContentJson(v: PreviewPart): JsonObject = when (v) {
    is PreviewPart.Text -> nativeContentObject("type" to "Text", "text" to v.text)
    is PreviewPart.Placeholder -> nativeContentObject("type" to "Placeholder", "kind" to v.kind.name)
}
internal fun nativeContentJson(v: MessageConversation): JsonObject = nativeContentObject(
    "uid" to v.uid, "userName" to v.userName, "avatarUrl" to v.avatarUrl,
    "snippet" to nativeContentArray(v.snippet, ::nativeContentJson), "isSnippetMine" to v.isSnippetMine,
    "updatedAtMillis" to v.updatedAtMillis, "updatedAtText" to v.updatedAtText,
    "unreadCount" to v.unreadCount, "isSystem" to v.isSystem,
)
internal fun nativeContentJson(v: DirectMessage): JsonObject = nativeContentObject(
    "id" to v.id,
    "isMine" to v.isMine,
    "content" to v.content,
    "isMarkdown" to v.isMarkdown,
    "sentAtMillis" to v.sentAtMillis,
    "sentAtText" to v.sentAtText,
)
internal fun nativeContentJson(v: MessageThread): JsonObject = nativeContentObject(
    "uid" to v.uid,
    "userName" to v.userName,
    "avatarUrl" to v.avatarUrl,
    "level" to v.level,
    "messages" to nativeContentArray(v.messages, ::nativeContentJson),
    "unreadIds" to nativeContentLongs(v.unreadIds),
    "createdAt" to v.createdAt,
)
