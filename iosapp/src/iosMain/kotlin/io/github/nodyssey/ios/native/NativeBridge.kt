package io.github.nodyssey.ios.native

import io.github.nodyssey.data.imagehost.ImageHostError
import io.github.nodyssey.data.imagehost.ImageHostException
import io.github.nodyssey.data.session.SessionState
import io.github.nodyssey.ios.IosAppContainer
import io.github.nodyssey.ios.NodysseyApp
import io.github.plaza.core.net.SiteError
import io.github.plaza.core.net.SiteException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** Swift owns this lifetime. Canceling also tears down Paging presenters and Room collectors. */
class NativeRequest internal constructor(private val job: Job) {
    fun cancel() {
        job.cancel()
    }
}

internal class NativeContext(val graph: IosAppContainer, val scope: CoroutineScope)

/** The only exported application-data ABI; all repository access starts on Main. */
object NativeBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val reconciliation = Mutex()
    private var reconciled: SessionState? = null

    fun request(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest =
        start(completion) {
            previewRequireOperation(operation, argumentsJson, false)
            val args = nativeArguments(argumentsJson)
            val graph = NodysseyApp.ensureContainer()
            val session = reconcile(graph)
            coroutineScope {
                val context = NativeContext(graph, this)
                // Cancel an in-flight repository reader/writer on a published session change,
                // rather than merely hiding a stale result after it has repopulated Room.
                val changesSession = operation in setOf("session.sync", "session.signIn", "session.verifyTwoFactor", "session.signOut")
                val watcher = if (changesSession) {
                    null
                } else {
                    launch {
                        graph.sessionRepository.state.collect { nativeCheckSession(session, graph.sessionRepository.peek()) }
                    }
                }
                try {
                    val data = context.contentRequest(operation, args)
                        ?: context.accountRequest(operation, args)
                        ?: context.settingsRequest(operation, args)
                        ?: context.supplementRequest(operation, args)
                        ?: throw NativeFailure("UNKNOWN_OPERATION")
                    if (!changesSession) nativeCheckSession(session, graph.sessionRepository.peek())
                    nativeDeliver(coroutineContext[Job]!!, data, completion)
                } finally {
                    watcher?.cancel()
                }
            }
        }

    fun observe(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest =
        start(completion) {
            previewRequireOperation(operation, argumentsJson, true)
            val args = nativeArguments(argumentsJson)
            val graph = NodysseyApp.ensureContainer()
            // collectLatest cancels old readers before reconciling or exposing the next account.
            var previous: SessionState? = null
            graph.sessionRepository.state.collectLatest {
                val current = graph.sessionRepository.peek()
                if (previous?.let { it.isSignedIn != current.isSignedIn || it.fingerprint != current.fingerprint } == true) {
                    // Clear Swift's last rendered value immediately, before a new network read.
                    // Null is a session-boundary invalidation on every observation, not a row.
                    nativeDeliver(coroutineContext[Job]!!, JsonNull, completion)
                }
                val session = reconcile(graph)
                previous = session
                coroutineScope {
                    val context = NativeContext(graph, this)
                    val flow = context.contentObserve(operation, args)
                        ?: context.accountObserve(operation, args)
                        ?: context.settingsObserve(operation, args)
                        ?: context.supplementObserve(operation)
                        ?: throw NativeFailure("UNKNOWN_OPERATION")
                    flow.collect { data ->
                        nativeCheckSession(session, graph.sessionRepository.peek())
                        nativeDeliver(coroutineContext[Job]!!, data, completion)
                    }
                }
            }
        }

    private fun start(completion: (String) -> Unit, block: suspend CoroutineScope.() -> Unit): NativeRequest {
        val job = scope.launch {
            try {
                coroutineScope(block)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                coroutineContext.ensureActive()
                completion(nativeFailure(failure))
            }
        }
        return NativeRequest(job)
    }

    private suspend fun reconcile(graph: IosAppContainer): SessionState = reconciliation.withLock {
        val session = graph.sessionRepository.peek()
        if (!PreviewGuestPolicy.sessionAllowed(session.isSignedIn)) throw NativeFailure("PREVIEW_GUEST_ONLY")
        val old = reconciled
        val cleared = graph.postRepository.reconcileSession(session.isSignedIn, session.fingerprint)
        if (old != null && old != session && session.isSignedIn && !cleared) {
            graph.postRepository.invalidateCaches()
        }
        if (cleared) graph.notificationRepository.clearCounts()
        reconciled = session
        session
    }
}

internal fun previewRequireOperation(operation: String, argumentsJson: String, observing: Boolean) {
    val key = if (operation == "settings.set") nativeArguments(argumentsJson).nativeOptionalText("key") else null
    if (!PreviewGuestPolicy.allows(operation, observing, key)) throw NativeFailure("PREVIEW_GUEST_ONLY")
}

internal fun nativeCheckSession(before: SessionState, after: SessionState) {
    if (!PreviewGuestPolicy.sessionAllowed(after.isSignedIn)) throw NativeFailure("PREVIEW_GUEST_ONLY")
    if (before.isSignedIn != after.isSignedIn || before.fingerprint != after.fingerprint) {
        throw NativeFailure("SESSION_CHANGED")
    }
}

internal class NativeFailure(val code: String) : Exception()

internal fun nativeDeliver(job: Job, data: JsonElement, completion: (String) -> Unit) {
    job.ensureActive()
    completion(
        buildJsonObject {
            put("ok", true)
            put("data", data)
        }.toString(),
    )
}

internal fun nativeFailure(failure: Throwable): String {
    if (failure is CancellationException) throw failure
    val code = when (failure) {
        is NativeFailure -> failure.code

        is SiteException -> when (failure.error) {
            is SiteError.Cloudflare -> "CHALLENGE"
            SiteError.LoginRequired -> "LOGIN_REQUIRED"
            SiteError.SessionUnrecognised -> "SESSION_UNRECOGNISED"
            is SiteError.LevelRequired -> "LEVEL_REQUIRED"
            SiteError.PrivatePost -> "PRIVATE_POST"
            SiteError.QueryTooShort -> "QUERY_TOO_SHORT"
            SiteError.RateLimited -> "RATE_LIMITED"
            is SiteError.Http -> "HTTP"
            SiteError.Network -> "NETWORK"
            SiteError.Unparsable -> "UNPARSABLE"
            SiteError.NotWired -> "UNSUPPORTED"
            SiteError.Unknown -> "REFUSED"
        }

        is ImageHostException -> when (failure.error) {
            ImageHostError.NotConfigured -> "IMAGE_HOST_NOT_CONFIGURED"
            ImageHostError.InvalidKey -> "IMAGE_HOST_INVALID_KEY"
            is ImageHostError.Rejected -> "IMAGE_HOST_REJECTED"
            ImageHostError.Cloudflare -> "IMAGE_HOST_CHALLENGE"
            is ImageHostError.Http -> "IMAGE_HOST_HTTP"
            ImageHostError.Network -> "NETWORK"
            ImageHostError.Unparsable -> "UNPARSABLE"
            ImageHostError.Unsupported -> "UNSUPPORTED"
            ImageHostError.InsecureLink -> "INSECURE_LINK"
        }

        is IllegalArgumentException -> "INVALID_ARGUMENT"

        is UnsupportedOperationException -> "UNSUPPORTED"

        else -> "INTERNAL"
    }
    // Never export Throwable.message/detail/cause or a challenged URL containing credentials.
    return buildJsonObject {
        put("ok", false)
        put(
            "error",
            buildJsonObject {
                put("code", code)
                put("message", "Operation could not be completed.")
            },
        )
    }.toString()
}

internal fun nativeArguments(value: String): JsonObject =
    try {
        Json.parseToJsonElement(value) as? JsonObject ?: throw NativeFailure("INVALID_ARGUMENT")
    } catch (_: IllegalArgumentException) {
        throw NativeFailure("INVALID_ARGUMENT")
    }

internal fun JsonObject.nativeText(key: String): String = nativeOptionalText(key) ?: throw NativeFailure("INVALID_ARGUMENT")
internal fun JsonObject.nativeOptionalText(key: String): String? {
    val value = this[key] ?: return null
    if (value == JsonNull) return null
    return (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw NativeFailure("INVALID_ARGUMENT")
}
internal fun JsonObject.nativeLong(key: String): Long {
    val value = this[key] as? JsonPrimitive ?: throw NativeFailure("INVALID_ARGUMENT")
    return value.takeUnless { it.isString }?.longOrNull ?: throw NativeFailure("INVALID_ARGUMENT")
}
internal fun JsonObject.nativeInt(key: String, default: Int? = null): Int {
    if (!containsKey(key) && default != null) return default
    val n = nativeLong(key)
    if (n < Int.MIN_VALUE || n > Int.MAX_VALUE) throw NativeFailure("INVALID_ARGUMENT")
    return n.toInt()
}
internal fun JsonObject.nativeBoolean(key: String, default: Boolean? = null): Boolean {
    if (!containsKey(key) && default != null) return default
    val value = this[key] as? JsonPrimitive ?: throw NativeFailure("INVALID_ARGUMENT")
    return value.takeUnless { it.isString }?.booleanOrNull ?: throw NativeFailure("INVALID_ARGUMENT")
}
internal inline fun <reified T : Enum<T>> JsonObject.nativeEnum(key: String, default: T? = null): T {
    val value = nativeOptionalText(key) ?: return default ?: throw NativeFailure("INVALID_ARGUMENT")
    return enumValues<T>().firstOrNull { it.name == value } ?: throw NativeFailure("INVALID_ARGUMENT")
}
internal fun JsonObject.nativeArray(key: String): JsonArray = this[key] as? JsonArray ?: throw NativeFailure("INVALID_ARGUMENT")
internal fun JsonObject.nativeObject(key: String): JsonObject = this[key] as? JsonObject ?: throw NativeFailure("INVALID_ARGUMENT")
internal fun JsonObject.nativePage(): Int = nativeInt("page", 1).also { if (it < 1) throw NativeFailure("INVALID_ARGUMENT") }
internal fun JsonObject.nativeId(key: String): Long = nativeLong(key).also { if (it <= 0) throw NativeFailure("INVALID_ARGUMENT") }
