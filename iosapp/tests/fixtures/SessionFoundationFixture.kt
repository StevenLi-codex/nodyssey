package platform.Foundation

/** Deterministic callback test double, NOT an emulation or proof of Foundation behavior. */
data class NSHTTPCookie(val name: String, val value: String, val domain: String, val path: String = "/")
class NSHTTPCookieStorage {
    private val jar = mutableListOf<NSHTTPCookie>()
    val cookies: List<NSHTTPCookie> get() = jar.toList()
    fun setCookie(cookie: NSHTTPCookie) {
        jar.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
        jar += cookie
    }
    fun deleteCookie(cookie: NSHTTPCookie) { jar.remove(cookie) }
    companion object { val sharedHTTPCookieStorage = NSHTTPCookieStorage() }
}
