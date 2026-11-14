package io.github.nodyssey.ios.native

import io.github.nodyssey.core.NodeSeekSite
import io.github.nodyssey.core.net.JsonSource
import io.github.nodyssey.data.*
import io.github.nodyssey.data.local.*
import io.github.nodyssey.data.session.*
import io.github.nodyssey.ios.IosAppContainer
import io.github.plaza.core.AppClock
import io.github.plaza.core.AppDispatchers
import io.github.plaza.core.net.*
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.*

private inline fun <reified T> fixture(crossinline answer: (String, Array<out Any?>) -> Any?): T = Proxy.newProxyInstance(
    T::class.java.classLoader, arrayOf(T::class.java),
) { _, method, args -> answer(method.name, args ?: emptyArray()) } as T

private class MemoryProfileDao : ProfileDao {
    private val row = MutableStateFlow<SelfProfileEntity?>(null)
    override fun observe(sessionFingerprint: Int) = row.map { it?.takeIf { it.sessionFingerprint == sessionFingerprint } }
    override suspend fun find(sessionFingerprint: Int) = row.value?.takeIf { it.sessionFingerprint == sessionFingerprint }
    override suspend fun upsert(profile: SelfProfileEntity) { row.value = profile }
    override suspend fun deleteAll() { row.value = null }
}

/** Only test I/O; no transport can contact a host or send a write. */
fun main(args: Array<String>) = runBlocking {
    val traces = Json.parseToJsonElement(File(args[0]).readText()).jsonArray
    var failures = 0
    for (trace in traces) {
        val scenario = trace.jsonObject.getValue("scenario").jsonPrimitive.content
        var stars = 100
        var chickens = 300
        var profileFetches = 0
        val cookies = object : SessionCookieStore {
            override fun cookieHeader(url: String) = "${NodeSeekSite.CONFIG.sessionCookieNames.first()}=library-fixture"
            override fun setCookie(url: String, cookie: String): Unit = error("No writes")
            override suspend fun removeAll(): Unit = error("No writes")
            override fun flush() = Unit
        }
        val session = SessionRepository(SessionCookies(NodeSeekSite.CONFIG, cookies))
        val clock = AppClock { 1_000L } // never advance past the 60-second cache TTL
        val json = fixture<JsonSource> { method, call ->
            check(method == "getJson")
            val path = call[0] as String
            if (path.contains("account")) {
                profileFetches++
                """{"data":{"member_id":31037,"member_name":"fixture","rank":2,"coin":$chickens,"stardust":$stars}}"""
            } else "{}"
        }
        val profile = NetworkProfileRepository(
            fixture<HtmlSource> { method, _ -> check(method == "getHtml"); File(args[1]).readText() },
            json, MemoryProfileDao(), { session.peek().fingerprint }, { true }, clock,
        )
        val credit = fixture<CreditRepository> { _, _ -> error("No ledger fixture needed") }
        val assets = NetworkAssetsRepository(profile, credit, json, AppDispatchers(), clock)
        val dust = fixture<StardustRepository> { method, _ ->
            check(method == "entries") { "Unexpected stardust operation $method" }
            StardustLedgerPage(emptyList(), null, false)
        }
        val context = NativeContext(IosAppContainer(mapOf(
            "sessionRepository" to session, "profileRepository" to profile,
            "assetsRepository" to assets, "stardustRepository" to dust,
        )), this)
        val empty = JsonObject(emptyMap())
        val prime = context.accountRequest("assets.growth", empty)!!.jsonObject
        check(prime["starCount"]!!.jsonPrimitive.int == 100)
        check(prime["chickenCount"]!!.jsonPrimitive.int == 300)
        // The fixture server changed, but the real repository's cache is still primed.
        stars = 93
        chickens = 304
        check(profile.profile().starCount == 100) { "Fixture did not prime the real profile cache" }
        var growth: JsonObject? = null
        for (request in trace.jsonObject.getValue("requests").jsonArray) {
            val operation = request.jsonObject.getValue("operation").jsonPrimitive.content
            // The Swift mutation was simulated; never replay any writes into Kotlin.
            if (operation in setOf("assets.transfer", "attendance.sign")) {
                stars = 92
                chickens = 305
                continue
            }
            check(operation in setOf("profile.self", "assets.stardust", "assets.growth", "attendance.status"))
            if (operation == "attendance.status") continue // status is not the profile cache under test
            val result = context.accountRequest(operation, request.jsonObject.getValue("arguments").jsonObject)
            if (operation == "assets.growth") growth = result!!.jsonObject
        }
        val observedStars = growth?.get("starCount")?.jsonPrimitive?.int
        val observedChickens = growth?.get("chickenCount")?.jsonPrimitive?.int
        if (observedStars != 92 || observedChickens != 305) {
            failures++
            println("FAIL $scenario: primed cache/server changed; expected stars=92 chickens=305, actual stars=$observedStars chickens=$observedChickens (profile fetches=$profileFetches)")
        } else {
            val refreshes = trace.jsonObject.getValue("requests").jsonArray.count {
                it.jsonObject["operation"]?.jsonPrimitive?.content == "profile.self" &&
                    it.jsonObject["arguments"]?.jsonObject?.get("refresh")?.jsonPrimitive?.booleanOrNull == true
            }
            check(profileFetches == 1 + refreshes) { "Unexpected profile fetch count" }
            println("PASS $scenario: real cache refreshed to stars=92 chickens=305; profile fetches=$profileFetches")
        }
    }
    check(failures == 0) { "$failures repository-backed Library regression(s) failed" }
    println("PASS ${traces.size} repository-backed replay scenarios; no network or writes")
}
