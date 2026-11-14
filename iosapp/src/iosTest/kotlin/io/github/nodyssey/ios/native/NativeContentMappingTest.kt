package io.github.nodyssey.ios.native

import io.github.nodyssey.data.FeedPost
import io.github.nodyssey.data.NotificationCategory
import io.github.nodyssey.data.NotificationSource
import io.github.nodyssey.model.PostSummary
import io.github.plaza.core.richtext.RichNode
import io.github.plaza.core.richtext.parseMarkdown
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals

class NativeContentMappingTest {
    @Test
    fun `feed identity survives JSON beyond double precision and missing page remains null`() {
        val row = FeedPost(PostSummary(9007199254740993L, "title", "author", null, null, null, null, null, 3, null, null), true, 2)
        val encoded = nativeContentJson(row).toString()
        val decoded = Json.parseToJsonElement(encoded).jsonObject
        assertEquals(9007199254740993L, decoded["summary"]!!.jsonObject["postId"]!!.jsonPrimitive.long)
        assertEquals(JsonNull, decoded["page"])
        assertEquals(2, decoded["newCommentCount"]!!.jsonPrimitive.int)
    }

    @Test
    fun `preview retains canonical rich node discriminator and nested structure`() {
        val nodes = parseMarkdown("**bold** [link](https://example.org)\n\n> quoted")
        val encoded = nativeRichNodes(nodes)
        assertEquals(nodes, Json.decodeFromJsonElement(ListSerializer(RichNode.serializer()), encoded))
        assertNotEquals(JsonArray(emptyList()), encoded)
    }

    @Test
    fun `notification source retains both categories and absent viewed identity`() {
        val sources = listOf(NotificationSource(NotificationCategory.REPLIES, 17, true), NotificationSource(NotificationCategory.MENTIONS, null, true))
        val encoded = sources.map(::nativeContentJson)
        assertEquals("REPLIES", encoded[0].jsonObject["category"]!!.jsonPrimitive.content)
        assertEquals(JsonNull, encoded[1].jsonObject["viewedId"])
    }

    @Test
    fun `read position rejects zero page instead of overwriting valid bookmark`() {
        assertFailsWith<NativeFailure> { Json.parseToJsonElement("""{"page":0}""").jsonObject.nativePage() }
    }
}
