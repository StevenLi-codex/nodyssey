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
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
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

    /** File leases release on actual Job termination, never on cancellation/result delivery. */
    fun invokeOnCompletion(completion: () -> Unit) {
        job.invokeOnCompletion { drainCallbacks.launch { completion() } }
    }

    private companion object {
        val drainCallbacks = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    }
}

internal class NativeContext(val graph: IosAppContainer, val scope: CoroutineScope)

/** The only exported application-data ABI; all repository access starts on Main. */
object NativeBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val sessionControls = setOf("session.signIn", "session.verifyTwoFactor", "session.signOut")

    private fun publicOperation(operation: String): Boolean = operation.startsWith("session.") ||
        operation in setOf("settings.get", "settings.set", "settings.observe", "settings.theme.save", "settings.theme.delete",
            "settings.homeBoards", "settings.toolbar", "settings.capabilities", "settings.metadata", "platform.context", "app.foreground")

    fun request(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest {
        // Main-confined one-shot: reentrant revocation may fail lease exit after success.
        var published = false
        val publish: (String) -> Unit = { result ->
            if (!published) {
                published = true
                completion(result)
            }
        }
        return start(publish) {
            val args = nativeArguments(argumentsJson)
            if (operation == "site.get") {
                // Bootstrap only the public catalogue/selection. Constructing the graph or
                // reconciling provenance here can strand recovery before its observers start.
                nativeDeliver(coroutineContext[Job]!!, NodysseyApp.nativeSiteMetadata(), publish)
                return@start
            }
            val graph = NodysseyApp.ensureContainer()
            if (operation == "session.sync") {
                nativeSupersedeAuthentication()
                graph.sessionRepository.sync()
                graph.privateBoundary.reconcileIfIdle()
            } else if (operation == "session.cancelSignIn") {
                // Do not queue cancellation behind the operation it must supersede.
            } else {
                graph.privateBoundary.reconcileIfIdle()
            }
            coroutineScope {
                val context = NativeContext(graph, this)
                suspend fun dispatch(): JsonElement = context.contentRequest(operation, args)
                    ?: context.accountRequest(operation, args)
                    ?: context.settingsRequest(operation, args)
                    ?: context.supplementRequest(operation, args)
                    ?: throw NativeFailure("UNKNOWN_OPERATION")
                if (!publicOperation(operation)) {
                    graph.privateBoundary.protect {
                        val data = dispatch()
                        // Keep publication in the admitted lease, and recheck identity after dispatch.
                        // Use the lease Job, not the enclosing request scope's still-active Job.
                        graph.privateBoundary.protect {
                            nativeDeliver(currentCoroutineContext()[Job]!!, data, publish)
                        }
                    }
                    return@coroutineScope
                }
                val data = when (operation) {
                    "session.sync" -> context.nativeSessionDto()
                    "session.privateBoundary" -> graph.privateBoundary.state.value.nativeBoundaryDto()
                    "session.resetPrivateStores" -> {
                        graph.privateBoundary.reset(args.nativeBoolean("confirmed"), args.nativeText("identityEpoch"))
                        graph.privateBoundary.state.value.nativeBoundaryDto()
                    }
                    in sessionControls -> graph.privateBoundary.sessionMutation { dispatch() }.let { result ->
                        // Auth DTOs were assembled before finally reconciled the jar. Never export an old epoch.
                        val session = context.nativeSessionDto()
                        if (operation in setOf("session.sync", "session.signOut")) session
                        else if (result is JsonObject && result.containsKey("session")) JsonObject(result + ("session" to session)) else result
                    }
                    else -> dispatch()
                }
                nativeDeliver(coroutineContext[Job]!!, data, publish)
            }
        }
    }

    fun observe(operation: String, argumentsJson: String, completion: (String) -> Unit): NativeRequest =
        start(completion) {
            val args = nativeArguments(argumentsJson)
            val graph = NodysseyApp.ensureContainer()
            graph.privateBoundary.reconcile()
            if (operation == "session.privateBoundary") {
                graph.privateBoundary.state.collect { nativeDeliver(coroutineContext[Job]!!, it.nativeBoundaryDto(), completion) }
                return@start
            }
            if (publicOperation(operation)) {
                coroutineScope {
                    val context = NativeContext(graph, this)
                    val flow = context.accountObserve(operation, args) ?: context.settingsObserve(operation, args)
                        ?: context.supplementObserve(operation) ?: throw NativeFailure("UNKNOWN_OPERATION")
                    flow.collect { nativeDeliver(coroutineContext[Job]!!, it, completion) }
                }
                return@start
            }
            graph.privateBoundary.state.collectLatest { boundary ->
                nativeDeliver(coroutineContext[Job]!!, JsonNull, completion)
                if (boundary.phase != io.github.nodyssey.data.session.PrivateStorePhase.READY) return@collectLatest
                coroutineScope {
                    val context = NativeContext(graph, this)
                    val flow = context.contentObserve(operation, args) ?: context.accountObserve(operation, args)
                        ?: context.settingsObserve(operation, args) ?: context.supplementObserve(operation)
                        ?: throw NativeFailure("UNKNOWN_OPERATION")
                    graph.privateBoundary.protect {
                        flow.collect { data -> graph.privateBoundary.protect { nativeDeliver(coroutineContext[Job]!!, data, completion) } }
                    }
                }
            }
        }

    private fun start(completion: (String) -> Unit, block: suspend CoroutineScope.() -> Unit): NativeRequest {
        val job = scope.launch {
            try {
                coroutineScope(block)
            } catch (cancelled: CancellationException) {
                coroutineContext.ensureActive()
                if (cancelled is io.github.nodyssey.data.session.PrivateWorkRevoked) completion(nativeFailure(NativeFailure("SESSION_CHANGED")))
                else throw cancelled
            } catch (failure: Exception) {
                coroutineContext.ensureActive()
                completion(nativeFailure(failure))
            }
        }
        return NativeRequest(job)
    }


}

internal fun io.github.nodyssey.data.session.PrivateBoundaryState.nativeBoundaryDto(): JsonObject = buildJsonObject {
    put("phase", phase.name)
    put("identityEpoch", identityEpoch)
    put("requiresConfirmation", requiresConfirmation)
    put("recoveryEligible", recoveryEligible)
}

internal fun NativeContext.nativeSessionDto(): JsonObject = JsonObject(graph.sessionRepository.state.value.accountDto() +
    ("identityEpoch" to JsonPrimitive(graph.privateBoundary.state.value.identityEpoch)))

internal fun nativeCheckSession(before: SessionState, after: SessionState) {
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
        is io.github.nodyssey.data.session.PrivateStoreAccessDenied -> "PRIVATE_STORE_RECOVERY_REQUIRED"

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
