package io.github.nodyssey.ios.native

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import io.github.nodyssey.core.Site
import io.github.nodyssey.core.report.QualityReport
import io.github.nodyssey.data.settings.SettingsRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okio.FileSystem
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.uuid.Uuid

class NativeSupplementTest {
    @Test
    fun foregroundWaitsForGraphThenInvokesTheExistingScheduler() = runBlocking {
        val order = mutableListOf<String>()
        supplementForeground({ order += "ready" }, { order += "onLaunch" })
        assertEquals(listOf("ready", "onLaunch"), order)
        order.clear()
        assertFailsWith<IllegalStateException> {
            supplementForeground({ error("graph unavailable") }, { order += "onLaunch" })
        }
        assertTrue(order.isEmpty())
        assertFailsWith<kotlinx.coroutines.CancellationException> {
            supplementForeground({ throw kotlinx.coroutines.CancellationException() }, { order += "onLaunch" })
        }
        assertTrue(order.isEmpty())
    }

    @Test
    fun siteSelectionKeepsRunningOriginAndCanCancelPendingRestart() {
        // Storage boundary is injected here; no claim that JVM executes NSUserDefaults.
        var stored: String? = null
        fun request(site: String) = supplementSiteRequest("site.select", settingsObject("site" to site), Site.NODESEEK, { stored }, { stored = it })!!
        val pending = request("DEEPFLOOD")
        assertEquals("NODESEEK", pending["current"]!!.jsonPrimitive.content)
        assertEquals("DEEPFLOOD", pending["selected"]!!.jsonPrimitive.content)
        assertEquals("true", pending["requiresRestart"].toString())
        assertEquals(Site.NODESEEK.origin, pending["sites"]!!.jsonArray.first().jsonObject["origin"]!!.jsonPrimitive.content)
        val reverted = request("NODESEEK")
        assertEquals("false", reverted["requiresRestart"].toString())
        assertEquals("NODESEEK", stored)
        assertFailsWith<IllegalArgumentException> { request("deepflood") }
        assertEquals("NODESEEK", stored)
        assertFailsWith<IllegalStateException> {
            supplementSiteRequest("site.select", settingsObject("site" to "DEEPFLOOD"), Site.NODESEEK, { "NODESEEK" }, {})
        }
    }

    @Test
    fun historyMutationsKeepTargetScopeSortAndPersistAcrossReopen() = runBlocking {
        val path = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "native-supplement-${Uuid.random()}.preferences_pb"
        var job = SupervisorJob()
        fun repository() = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { path }))
        try {
            var repository = repository()
            val post = settingsObject("query" to "  vps  ", "target" to "POSTS", "categorySlug" to "tech")
            val user = settingsObject("query" to "vps", "target" to "USERS")
            val recorded = supplementSettingsRequest(repository, "search.history.record", post)!!.jsonArray
            assertEquals("vps", recorded.single().jsonObject["query"]!!.jsonPrimitive.content)
            assertEquals("POST_TIME", recorded.single().jsonObject["sort"]!!.jsonPrimitive.content)
            supplementSettingsRequest(repository, "search.history.record", post)
            supplementSettingsRequest(repository, "search.history.record", user)
            val otherBoard = settingsObject("query" to "vps", "target" to "POSTS", "categorySlug" to "trade")
            val otherSort = settingsObject("query" to "vps", "target" to "POSTS", "categorySlug" to "tech", "sort" to "LAST_REPLY")
            supplementSettingsRequest(repository, "search.history.record", otherBoard)
            supplementSettingsRequest(repository, "search.history.record", otherSort)
            job.cancelAndJoin()
            job = SupervisorJob()
            repository = repository()
            assertEquals(4, supplementSettingsRequest(repository, "search.history.get", settingsObject())!!.jsonArray.size)
            assertFailsWith<IllegalArgumentException> {
                supplementSettingsRequest(repository, "search.history.record", settingsObject("query" to "never saved", "target" to "INVALID"))
            }
            val afterRemoval = supplementSettingsRequest(repository, "search.history.remove", otherSort)!!.jsonArray
            assertEquals(3, afterRemoval.size)
            assertEquals(afterRemoval, supplementHistory(repository).first())
            val cleared = supplementSettingsRequest(repository, "search.history.clear", settingsObject("target" to "POSTS"))!!.jsonArray
            assertEquals("USERS", cleared.single().jsonObject["target"]!!.jsonPrimitive.content)
            val removed = supplementSettingsRequest(repository, "search.history.remove", user)!!.jsonArray
            assertTrue(removed.isEmpty())
        } finally {
            job.cancelAndJoin()
            FileSystem.SYSTEM.delete(path, mustExist = false)
        }
    }

    @Test
    fun recentBoardsAreRepositoryMruAndWholeSiteDoesNotCreateABoard() = runBlocking {
        val path = FileSystem.SYSTEM_TEMPORARY_DIRECTORY / "native-supplement-${Uuid.random()}.preferences_pb"
        var job = SupervisorJob()
        fun repository() = SettingsRepository(PreferenceDataStoreFactory.createWithPath(scope = CoroutineScope(job + Dispatchers.Default), produceFile = { path }))
        try {
            var repository = repository()
            for (slug in listOf("tech", "trade", "tech", null, "")) {
                supplementSettingsRequest(repository, "boards.recent.record", settingsObject("categorySlug" to slug))
            }
            job.cancelAndJoin()
            job = SupervisorJob()
            repository = repository()
            val recent = supplementSettingsRequest(repository, "boards.recent.get", settingsObject())
            assertEquals(Json.parseToJsonElement("[\"tech\",\"trade\"]"), recent)
            assertEquals(recent, supplementRecentBoards(repository).first())
        } finally {
            job.cancelAndJoin()
            FileSystem.SYSTEM.delete(path, mustExist = false)
        }
    }

    @Test
    fun yabsUsesSharedParserAndAnsiSpansPreserveRiskTone() {
        // Header/section shape from checked-in reports/nodequality-yabs.txt.
        val yabs = """
            ########
            https://github.com/LloydAsp/NodeQuality
            报告时间：2025-03-24 10:39:57 CST  脚本版本：v0.0.1
            ########
            Basic System Information:
            ---------------------------------
            Processor  : Intel Xeon Processor (SierraForest)
            CPU cores  : 2 @ 2699.998 MHz
        """.trimIndent()
        val report = Json.decodeFromJsonElement<QualityReport>(supplementParseReport(settingsObject("code" to yabs)))
        assertEquals("NodeQuality", report.title)
        assertEquals("Basic System Information", report.sections.single().title)
        assertEquals("Processor", (report.sections.single().blocks.first() as QualityReport.Block.Field).label)
        val ansi = "++++++++\nIP质量体检报告：1.2.3.4\n++++++++\n一、风险\n风险：\u001b[31m高风险\u001b[0m\n========"
        val decoded = io.github.plaza.core.ansi.AnsiDecoder.decode(ansi)
        val rawResult = supplementParseReport(settingsObject("code" to ansi))
        val spanResult = supplementParseReport(settingsObject("code" to decoded.text, "spans" to Json.encodeToJsonElement(kotlinx.serialization.builtins.ListSerializer(io.github.plaza.core.ansi.AnsiSpan.serializer()), decoded.spans)))
        assertEquals(rawResult, spanResult)
        val coloured = Json.decodeFromJsonElement<QualityReport>(spanResult)
        val field = coloured.sections.single().blocks.single() as QualityReport.Block.Field
        assertEquals(QualityReport.Tone.Bad, field.values.single().tone)
    }

    @Test
    fun reportParserPreservesSharedStructureAndRejectsOrdinaryCode() {
        val code = """
            ++++++++
            IP质量体检报告：1.2.3.4
            报告时间：2026-07-28 12:14:43 CST  脚本版本：v2026-03-29
            ++++++++
            一、基本信息
            地址：example
            ========
        """.trimIndent()
        val report = Json.decodeFromJsonElement<QualityReport>(supplementParseReport(settingsObject("code" to code)))
        assertEquals("IP质量体检报告", report.title)
        assertEquals("1.2.3.4", report.target)
        assertTrue(report.sections.isNotEmpty())
        assertEquals(JsonNull, supplementParseReport(settingsObject("code" to "print(42)")))
    }
}
