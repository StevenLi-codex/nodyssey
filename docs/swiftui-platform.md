# SwiftUI platform integration

## Scope and attribution

These adapters target **iOS 16**. They do not render a Compose screen. `NativePlatform.kt` builds on the existing authors' `NodysseyApp.ensureContainer`, `WebKitCookieBridge`, `NodeSeekSite`, `IosImageLoader`, `IosOfflineFileStore`, and `IosSvgDecoder`/`WebKitSvgRasterizer`; their source, licensing and authorship are unchanged. Turnstile document/message handling is adapted from `ui/login/TurnstileWidget.kt` because those helpers are module-internal. The static one-tap script remains the original `Site.oneTapSignIn.triggerScript`.

Framework import: `NodysseyShell`. All facade calls and callbacks are on Main. This document records intended Swift names; the generated Objective-C header and an actual Xcode build remain the authoritative integration check.

## Kotlin ABI / Swift call sites

```swift
let request: NativeRequest = NativePlatform.shared.ready { context, errorCode in ... }
request.cancel()
// context: NativePlatformContext?; errorCode: String?
// context.baseUrl, context.userAgent, context.usesDefaultUserAgent,
// context.oneTapSignInPath (optional; nil when site has no one-tap provider)

let request = NativePlatform.shared.image(url: absoluteURL, allowMetered: false) { data, errorCode in ... }
// Kotlin NSData? imports as Foundation Data?; callback is not JSON.
// Original PNG/JPEG/GIF/WebP when available, otherwise worker-encoded PNG.

NativePlatform.shared.isTrustedBrowserUrl(url: value)
NativePlatform.shared.isBrowserUrl(url: value, goal: "telegramBind")
NativePlatform.shared.isExternalBrowserUrl(url: value)
NativePlatform.shared.oneTapScript(url: value) // only exact active-site one-tap page; otherwise nil
NativePlatform.shared.turnstileDocument(darkTheme: false)
NativePlatform.shared.turnstileMessageKind(kind: "token", value: token)

let session = NativeBrowserSession(cookieStore: WKWebsiteDataStore.default().httpCookieStore, goal: "login")
session.start { context, errorCode in ... } // load WKWebView only here, after successful seed/start
session.goalReached()                     // mirror read, NOT session.sync()
session.close { errorCode in ... }        // callback after stop/drain/sync
```

`NativeRequest.cancel()` cancels graph-await/image/observer work and suppresses callbacks. A synchronous raster/encode must unwind before its coroutine releases resources; its result is discarded on cancellation. Error codes are sanitized and contain no underlying exception, URL, cookie, proxy secret, password or token. Codes: `PLATFORM_UNAVAILABLE`, `IMAGE_UNAVAILABLE`, `IMAGE_WIFI_ONLY`, `BROWSER_CLOSED`, `BROWSER_BUSY`, `BROWSER_UNAVAILABLE`, `COOKIE_SYNC_FAILED`.

Browser start/close are deliberately **not** Swift-task-cancellable: the final drain must outlive disappearance. Every caller must call `close`, including a swipe dismissal, route replacement or failure during setup. Close is idempotent; closing while seed is suspended prevents the observer from subsequently starting. Only one native authentication browser may own the shared store at a time; a second receives `BROWSER_BUSY`. Do not run the old Compose browser concurrently.

## SwiftUI constructors

```swift
NativeBrowser(url: "", title: "Sign in", goal: .login, onFinished: { /* refresh route-owned data */ })
NativeBrowser(url: "", title: "Sign in", goal: .oneTapLogin)
NativeBrowser(url: challengedURL, title: "Verification", goal: .challenge)
NativeBrowser(url: "/setting#contact", title: "Contact", goal: .manage)
NativeBrowser(url: "", title: "Telegram", goal: .telegramBind)
NativeExternalBrowser(url: publicURL) // UIViewControllerRepresentable, present in .sheet

NativeTurnstile(darkTheme: false, resetSignal: 0,
                onToken: { token in /* transient form state only */ },
                onExpired: { /* clear token, disable submit */ },
                onUnavailable: { /* clear token, show retry/web-sign-in */ })
    .frame(height: 72)

NativeRemoteImage(url: absoluteURL, aspectFit: true)
NativeImageViewer(url: absoluteURL)
NativeImageGallery(urls: urls, initialIndex: index)
NativeShare(items: [publicTextOrImage], onComplete: { completed in ... })
```

`url` is required for `NativeBrowser`; empty selects the goal's default page, a single-leading-slash path resolves against the ready active site, and absolute URLs must pass the trusted gate. Scheme-relative URLs are not resolved. Browser `onFinished` runs after final cookie synchronization on explicit close/goal completion. An interactive dismissal still drains and publishes the Kotlin session but does not issue a second presentation callback; observe session changes for data refresh instead of depending exclusively on `onFinished`.

`NativeRemoteImage` includes loading, retry/deferred-data state, stale-URL protection, cancellation on disappearance and a full-screen image destination. `NativeImageViewer` adds pinch/pan zoom, explicit save and share. `NativeImageGallery` supplies page swiping. GIF frames decode via ImageIO on a worker, with bounded decoded pixel/frame counts; oversized animations intentionally display a static image rather than allocating without limit. Saving uses the retained original raster bytes (SVG is saved as PNG), only after the Save button and add-only Photos authorization. Existing `NSPhotoLibraryAddUsageDescription` is present in Info.plist; no additional permission or automatic photo write is introduced. Sharing loaded images passes `UIImage`, not an authenticated network URL. Do not pass credentials/private URLs into the general-purpose `NativeShare(items:)` API.

## Browser boundaries and lifecycle

- Configuration uses the **default WKWebsiteDataStore** and its exact cookie store, and a `NativeBrowserSession` owns the existing shared Kotlin `WebKitCookieBridge`. Swift never copies cookie values or invents its own cookie jar.
- `ensureContainer` resolves the process's live WebKit UA first. Default UA is left default; an actual configured fallback is explicitly applied to main and popup views.
- Seed is awaited before observer start and before the first request. Teardown stops the observer, awaits the last drain, then calls `SessionRepository.sync` in `finally`, just like the existing screen.
- Login/one-tap/clearance goals require fingerprint change relative to opening baseline, not merely an old cookie's presence. Mirror checks are every 500 ms, followed by 500 ms settle. Telegram checks call the real `accountSettingsRepository.telegramBinding()` every 4 seconds; failed reads do not imply success.
- `NodeSeekSite.isTrustedWebViewUrl` remains authoritative: HTTPS/443, exact active-site hosts and that site's configured sign-in provider hosts. DeepFlood's NodeSeek provider is not confused with the active forum. Only `.manage` and `.telegramBind` additionally admit `isTelegramOAuthUrl`.
- Popup creation requires both a permitted source and destination, preserves WebKit's supplied configuration/opener relationship, shares UA/store, and handles `window.close`. No arbitrary new-window fallback or JavaScript URL is accepted. Automatic JavaScript windows remain disabled.
- The only one-tap evaluation is the existing static script, once, after the active site's exact configured one-tap page finishes. It is never evaluated on a provider/external page and accepts no caller-supplied script.
- External main-frame redirects are cancelled. A user-tapped ordinary external link can open a separate SFSafariViewController; only `.manage` has an explicit “Open in browser” toolbar action. Safari receives no cookies or headers from this app.
- `.manage` is for genuinely web-only account/invite flows, not a fallback for native application screens.

## Turnstile

The document is loaded once from a string using the active site's HTTPS base origin. Only its first main-frame navigation is accepted; subsequent main-frame or new-window navigations are rejected. The required Cloudflare HTTPS challenge subframe is admitted separately. The shim is installed only in the main frame.

Messages require the same WKWebView instance, expected handler name, main frame, exact base document URL, HTTPS origin/host and default HTTPS port. A nonblank `token` calls `onToken`, `expired` calls `onExpired`, and blank token/unknown/error events call `onUnavailable`. Provider error text is discarded. The widget never persists/logs a token, receives passwords, or makes sign-in requests itself.

Increment `resetSignal` after a consumed/refused token; the first observed reset value is skipped, so mounting a restored form does not immediately reset its new widget. Redraws and field editing do not reload HTML. If theme changes require a different widget document, replace the view identity deliberately and clear the form token. The form owns token expiry and must disable submission when unavailable. This component requires no Compose controller.

## Image routing and repaired baseline omissions

Normal network requests execute the **installed SingletonImageLoader**, so its existing live `forumSession.current`, proxy reconfiguration, cookies scoped by URLSession, UA/language/referrer/redirect rules, avatar cache strategy, and SVG decoder remain intact. No `URLSession.shared` client is introduced and no upload-host token is consulted.

Before loading, the facade reconciles persisted session provenance and captures the session identity. It checks the identity again before delivery. The application must also invalidate its presented account UI on session changes, including already displayed images; this adapter does not create a second account store. Disk/offline caches remain the original stores and are cleared by the existing account sign-out flow, not an independent Swift cache.

Two baseline gaps are now handled in the facade:

1. `IosOfflineFileStore.of(applicationSupportDirectory()).pathOf(url)` is checked before fetching. Downloaded bytes are fed through the same Coil decoder, including SVG; no second download root or invented path convention.
2. `settingsRepository.settings.first().imagesOnWifiOnly` is consumed per request. A cancellable one-shot Network.framework monitor checks Wi-Fi. Off Wi-Fi, memory/disk/offline bytes may still load, but a missing local source returns `IMAGE_WIFI_ONLY`. The explicit “Load using mobile data” action retries with `allowMetered: true`.

**Important implementation detail:** setting Coil `networkCachePolicy(DISABLED)` alone is insufficient for this repository's existing custom NetworkClient: Coil encodes the policy as `Cache-Control: only-if-cached`, but `UrlSessionNetworkClient` currently ignores request headers. The native facade therefore does not call a network fetcher in the deferred path; it supplies cache bytes through ByteArrayFetcher. This fixes the new native surface without modifying the shared/image-loader files outside ownership.

The existing SVG capture/worker mutex, pixel bounds, PDF→CoreGraphics→ImageIO pipeline are not recreated or changed. Bitmap/PNG conversion for the ABI runs on Dispatchers.Default and never closes a borrowed Coil bitmap.

## Parent integration evidence

The initial platform sources are committed in `92336381d6d61cd463c85e26070a32db4f5fd126`. Actions run `43555353912` completed actual `:iosapp:compileKotlinIosSimulatorArm64` including this facade. This proves Apple production source compilation only, not Objective-C/Swift call-site correctness or linking. Test compilation then exposed an undeclared `kotlinx-coroutines-test` import; commit `33d782448dde7baf600006639e047e48642196f2` preserves the cookie race test with explicit undispatched starts and the existing coroutine core dependency. The actual JVM core harness again passed all five cases after that correction. Simulator execution and the Swift app build still require the next CI run.

## Verification and remaining integration gates

- `iosapp/src/iosTest/.../NativePlatformTest.kt` covers seed/dismiss serialization, stop/drain/publish order and idempotent close; stale clearance/login fingerprints; Wi-Fi explicit override; Turnstile dispatch; hostile URL schemes/userinfo/parser ambiguity.
- `JAVA=<java21> python3 iosapp/tests/native_platform_core_test.py` compiles the actual marked platform-free production region and the actual tests with cached Kotlin 2.4.20/coroutines 1.11.0. **5 tests passed.** Missing implementation was observed failing before implementation; new Turnstile/Wi-Fi helpers also failed compilation before implementation.
- Scoped root `spotlessApply` succeeded. Linux host warns that Kotlin/Native is unsupported; this is not an iOS compile.
- `:shared:jvmTest --tests '*NodeSeekSiteTest*' --tests '*WebUrlTest*' --tests '*SessionRepositoryTest*'` succeeded, but XML contains **only 12 NodeSeekSiteTest cases**, all passed. The other named suites live outside that JVM target; they are not claimed as executed.
- Pending parent integration: add Swift sources to the application target, verify generated Kotlin export names, actual Kotlin/Native + Xcode build, simulator/device login/Cloudflare/OAuth popup tests, Turnstile origin callbacks, Photos permission denial/success, proxy traffic inspection, offline/Wi-Fi behavior and account-switch UI invalidation. No real login, posting or photo-library write was performed during this implementation.
