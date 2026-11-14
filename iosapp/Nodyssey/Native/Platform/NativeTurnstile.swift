import SwiftUI
import WebKit
import NodysseyShell

/// Native sign-in form widget. Tokens are ephemeral callback values: do not log or persist them.
struct NativeTurnstile: UIViewRepresentable {
    var darkTheme: Bool = false
    var resetSignal: Int = 0
    let onToken: (String) -> Void
    let onExpired: () -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let host = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(host, name: "__nsBridge")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.__nsBridge={post:function(kind,value){
                window.webkit.messageHandlers.__nsBridge.postMessage({kind:kind,value:value});
            }};
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = host
        host.web = web
        host.request = NativePlatform.shared.ready { [weak host, weak web] ready, error in
            guard let host, let web, !host.closed else { return }
            guard error == nil, let ready, let base = URL(string: ready.baseUrl + "/") else {
                host.parent.onUnavailable()
                return
            }
            host.base = base
            if !ready.usesDefaultUserAgent { web.customUserAgent = ready.userAgent }
            web.loadHTMLString(NativePlatform.shared.turnstileDocument(darkTheme: host.parent.darkTheme), baseURL: base)
        }
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        let host = context.coordinator
        host.parent = self
        // Do not reload HTML when SwiftUI redraws: a new form field value must not spend its token.
        if host.resetSignal != resetSignal {
            host.resetSignal = resetSignal
            onExpired()
            if host.documentReady { web.evaluateJavaScript("nsTurnstileReset()", completionHandler: nil) }
        }
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.closed = true
        coordinator.request?.cancel()
        web.stopLoading()
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "__nsBridge")
        web.configuration.userContentController.removeAllUserScripts()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: NativeTurnstile
        weak var web: WKWebView?
        var request: NativeRequest?
        var base: URL?
        var loaded = false
        var closed = false
        var documentReady = false
        var resetSignal: Int
        init(_ parent: NativeTurnstile) {
            self.parent = parent
            resetSignal = parent.resetSignal // skip the first reset, including restored non-zero values
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame == true {
                let allow = !loaded && url == base
                if allow { loaded = true }
                decisionHandler(allow ? .allow : .cancel)
            } else if action.targetFrame != nil {
                // This is the actual Turnstile frame, not an unrestricted subframe escape hatch.
                decisionHandler(url.scheme == "https" && url.host == "challenges.cloudflare.com"
                                && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
                                ? .allow : .cancel)
            } else { decisionHandler(.cancel) } // no new window
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !closed, loaded, message.webView === web, message.name == "__nsBridge",
                  message.frameInfo.isMainFrame, let base,
                  message.frameInfo.securityOrigin.protocol == "https",
                  message.frameInfo.securityOrigin.host == base.host,
                  [0, 443].contains(message.frameInfo.securityOrigin.port),
                  message.frameInfo.request.url == base else { return }
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String, let value = body["value"] as? String else {
                parent.onUnavailable()
                return
            }
            switch NativePlatform.shared.turnstileMessageKind(kind: kind, value: value) {
            case "token": parent.onToken(value)
            case "expired": parent.onExpired()
            default: parent.onUnavailable()
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { documentReady = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if !closed && (error as NSError).code != NSURLErrorCancelled { parent.onUnavailable() }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if !closed { parent.onUnavailable() }
        }
    }
}
