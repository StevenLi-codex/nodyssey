// Offline WebKit fixture. It never requests Cloudflare or a forum page.
@MainActor
final class FixtureNavigationDelegate: NSObject, WKNavigationDelegate {
    let host: NativeTurnstile.Coordinator
    var decisions: [String: Bool] = [:]
    init(_ host: NativeTurnstile.Coordinator) { self.host = host }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        host.webView(webView, decidePolicyFor: action) { policy in
            if let url = action.request.url, ["about:blank", "about:srcdoc"].contains(url.absoluteString) {
                self.decisions[url.absoluteString] = policy == .allow
            }
            decisionHandler(policy)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host.webView(webView, didFinish: navigation)
    }
}

MainActor.assumeIsolated {
    #if canImport(AppKit)
    _ = NSApplication.shared
    #endif
    var completed = false
    var unavailable = false
    let parent = NativeTurnstile(onToken: { _ in completed = true }, onExpired: {}, onUnavailable: { unavailable = true })
    let host = NativeTurnstile.Coordinator(parent)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController.add(host, name: "__nsBridge")
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 100), configuration: configuration)
    host.web = web
    host.base = URL(string: "https://www.nodeseek.com/")!
    let delegate = FixtureNavigationDelegate(host)
    web.navigationDelegate = delegate
    // Frame scripts report only local completion. A main-document message then
    // exercises the production URL/securityOrigin gate, not a fabricated token.
    web.loadHTMLString("""
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <script>
        const done = new Set();
        window.addEventListener('message', e => {
          if(e.data === 'blank' || e.data === 'srcdoc') done.add(e.data);
          if(done.size === 2) window.webkit.messageHandlers.__nsBridge.postMessage({kind:'token',value:'offline-fixture-only'});
        });
        const blank = document.createElement('iframe');
        blank.onload = () => blank.contentWindow.eval("parent.postMessage('blank','*')");
        blank.src = 'about:blank'; document.body.append(blank);
        const srcdoc = document.createElement('iframe');
        srcdoc.srcdoc = '<script>parent.postMessage("srcdoc","*")<\\/script>';
        document.body.append(srcdoc);
        </script></body></html>
        """, baseURL: host.base)
    let end = Date().addingTimeInterval(8)
    while !completed && !unavailable && Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let acceptedLocalFrames = delegate.decisions["about:blank"] == true && delegate.decisions["about:srcdoc"] == true
    print("WKWebView fixture: mainCallback=\(completed), unavailable=\(unavailable), localFramePolicy=\(delegate.decisions)")
    host.closed = true
    web.stopLoading()
    web.navigationDelegate = nil
    configuration.userContentController.removeScriptMessageHandler(forName: "__nsBridge")
    // No observed about: policy decision means this WebKit version cannot
    // validate the navigation regression. Do not silently label it a pass.
    guard completed && !unavailable && acceptedLocalFrames else { exit(1) }
    print("PASS: offline real WKWebView + production coordinator (not a Cloudflare solve)")
}
