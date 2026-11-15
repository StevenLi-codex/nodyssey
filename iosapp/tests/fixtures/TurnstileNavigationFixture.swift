@MainActor
func run() {
    let base = URL(string: "https://www.nodeseek.com/")!
    var tokenCount = 0
    let parent = NativeTurnstile(onToken: { _ in tokenCount += 1 }, onExpired: {}, onUnavailable: {})
    let host = NativeTurnstile.Coordinator(parent)
    let web = WKWebView()
    host.web = web
    host.base = base
    let origin = WKSecurityOrigin(protocol: "https", host: base.host!, port: 443)
    func policy(_ value: String, main: Bool? = false) -> WKNavigationActionPolicy {
        let request = URLRequest(url: URL(string: value)!)
        let frame = main.map { WKFrameInfo(isMainFrame: $0, request: request, securityOrigin: origin) }
        var result = WKNavigationActionPolicy.cancel
        host.webView(web, decidePolicyFor: WKNavigationAction(request: request, targetFrame: frame), decisionHandler: { result = $0 })
        return result
    }
    func check(_ value: Bool, _ label: String) {
        if !value { print("FAIL: \(label)"); exit(1) }
    }
    check(policy(base.absoluteString, main: true) == .allow, "initial document")
    check(policy("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/widget") == .allow, "challenge subframe")
    check(policy("about:blank") == .allow, "required about:blank challenge subframe is cancelled (spinner regression)")
    check(policy("about:srcdoc") == .allow, "required about:srcdoc challenge subframe")
    for url in [base.absoluteString, "about:blank", "about:srcdoc", "https://challenges.cloudflare.com/widget"] {
        check(policy(url, main: true) == .cancel, "main-frame escape: \(url)")
        check(policy(url, main: nil) == .cancel, "popup escape: \(url)")
    }
    for url in ["about:config", "about:blank?x=1", "about:srcdoc#x", "data:text/html,test", "javascript:void(0)", "file:///test", "http://challenges.cloudflare.com/", "https://challenges.cloudflare.com.evil.test/", "https://evil.test/", "https://u@challenges.cloudflare.com/", "https://challenges.cloudflare.com:444/"] {
        check(policy(url) == .cancel, "unexpected subframe: \(url)")
    }
    func message(_ view: WKWebView?, _ main: Bool, _ url: URL, _ security: WKSecurityOrigin) {
        host.userContentController(WKUserContentController(), didReceive: WKScriptMessage(webView: view, name: "__nsBridge", frameInfo: WKFrameInfo(isMainFrame: main, request: URLRequest(url: url), securityOrigin: security), body: ["kind": "token", "value": "fixture-only-not-a-provider-token"]))
    }
    message(web, false, base, origin)
    message(WKWebView(), true, base, origin)
    message(web, true, URL(string: "about:blank")!, origin)
    message(web, true, base, WKSecurityOrigin(protocol: "https", host: "challenges.cloudflare.com", port: 443))
    check(tokenCount == 0, "untrusted message accepted")
    message(web, true, base, origin)
    check(tokenCount == 1, "trusted main-document callback rejected")
    host.closed = true
    check(policy("about:blank") == .cancel, "closed host admitted frame")
    message(web, true, base, origin)
    check(tokenCount == 1, "post-close callback accepted")
    print("PASS: production coordinator navigation + message fixtures (boundary stand-ins; not WebKit/live challenge)")
}
MainActor.assumeIsolated { run() }
