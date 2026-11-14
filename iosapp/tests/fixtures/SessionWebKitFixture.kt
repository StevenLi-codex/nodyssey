package platform.WebKit

import platform.Foundation.NSHTTPCookie

/** Callback ordering fixture only. No claim that this models Apple scheduling or persistence. */
class WKHTTPCookieStore {
    val jar = mutableListOf<NSHTTPCookie>()
    private val observers = mutableSetOf<WKHTTPCookieStoreObserverProtocol>()
    var holdDelete: (() -> Unit)? = null
    var delayDelete = false
    fun setCookie(cookie: NSHTTPCookie, completion: () -> Unit) {
        jar.removeAll { it.name == cookie.name && it.domain == cookie.domain && it.path == cookie.path }
        jar += cookie
        observers.toList().forEach { it.cookiesDidChangeInCookieStore(this) }
        completion()
    }
    fun deleteCookie(cookie: NSHTTPCookie, completionHandler: () -> Unit) {
        val action = { jar.remove(cookie); completionHandler() }
        if (delayDelete) holdDelete = action else action()
    }
    fun getAllCookies(completion: (List<NSHTTPCookie>?) -> Unit) { completion(jar.toList()) }
    fun addObserver(observer: WKHTTPCookieStoreObserverProtocol) { observers += observer }
    fun removeObserver(observer: WKHTTPCookieStoreObserverProtocol) { observers -= observer }
}
interface WKHTTPCookieStoreObserverProtocol {
    fun cookiesDidChangeInCookieStore(cookieStore: WKHTTPCookieStore)
}
class WKWebsiteDataStore {
    val httpCookieStore = WKHTTPCookieStore()
    companion object {
        private val shared = WKWebsiteDataStore()
        fun defaultDataStore() = shared
    }
}
