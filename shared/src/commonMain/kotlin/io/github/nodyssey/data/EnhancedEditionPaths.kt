package io.github.nodyssey.data

/**
 * One fixed local edition, not an account workspace. No cookie, login generation, owner inference or
 * legacy-store discovery participates in these paths. Existing installations' bytes stay untouched.
 */
class EnhancedEditionPaths(applicationSupport: String, caches: String) {
    val supportRoot: String = "$applicationSupport/$NAMESPACE"
    val cacheRoot: String = "$caches/$NAMESPACE"

    companion object {
        // Keep stable across app versions and logins; a version bump must never reset local data.
        const val NAMESPACE = "io.github.nodyssey.upstream-enhanced-v1"
    }
}
