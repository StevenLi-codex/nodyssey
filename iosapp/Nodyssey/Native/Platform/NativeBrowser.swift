import SwiftUI
import WebKit
import SafariServices
import NodysseyShell

/// Authentication only. Ordinary content belongs to SwiftUI, not this browser.
enum NativeBrowserGoal: String { case login, oneTapLogin, challenge, manage, telegramBind }

struct NativeBrowser: View {
    let url: String
    var title: String = "Sign in"
    var goal: NativeBrowserGoal = .login
    var onFinished: () -> Void = {}
    @EnvironmentObject private var app: NativeAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var closeRequested = false
    @State private var externalSignal = 0
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                NativeAuthenticationWebView(app: app, url: url, goal: goal, closeRequested: closeRequested, externalSignal: externalSignal,
                    onFailure: { failure = $0 }, onClosed: {
                        Task {
                            // Close has already awaited the cookie bridge's final drain.
                            // Authentication and private admission are independent.
                            await app.refreshPrivateBoundary()
                            onFinished()
                            dismiss()
                        }
                    })
                if let failure {
                    Text(failure).font(.callout).padding().background(.regularMaterial)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { closeRequested = true }.disabled(closeRequested)
                }
                if goal == .manage {
                    ToolbarItem(placement: .primaryAction) {
                        Button { externalSignal += 1 } label: { Label("Open in browser", systemImage: "safari") }
                    }
                }
            }
        }
    }
}

private struct NativeAuthenticationWebView: UIViewControllerRepresentable {
    let app: NativeAppModel
    let url: String
    let goal: NativeBrowserGoal
    let closeRequested: Bool
    let externalSignal: Int
    let onFailure: (String) -> Void
    let onClosed: () -> Void

    func makeUIViewController(context: Context) -> AuthenticationController {
        // Register synchronously, before viewDidLoad -> start -> boundary emission.
        let token = goal == .login || goal == .oneTapLogin || goal == .challenge ? app.beginAuthenticationPresentation() : nil
        return AuthenticationController(url: url, goal: goal, onFailure: onFailure, onClosed: onClosed,
                                        onTeardown: { app.endAuthenticationPresentation(token) })
    }
    func updateUIViewController(_ controller: AuthenticationController, context: Context) {
        if closeRequested { controller.close(notify: true) }
        controller.openExternalIfRequested(externalSignal)
    }
    static func dismantleUIViewController(_ controller: AuthenticationController, coordinator: ()) {
        controller.close(notify: false)
    }
}

@MainActor
private final class AuthenticationController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let initialURL: String
    private let goal: NativeBrowserGoal
    private let onFailure: (String) -> Void
    private let onClosed: () -> Void
    private let onTeardown: () -> Void
    private var session: NativeBrowserSession?
    private var mainWebView: WKWebView?
    private var popup: WKWebView?
    private var poll: Task<Void, Never>?
    private var closed = false
    private var triggeredOneTap = false
    private var externalSignal = 0
    private let progress = UIActivityIndicatorView(style: .medium)

    init(url: String, goal: NativeBrowserGoal, onFailure: @escaping (String) -> Void,
         onClosed: @escaping () -> Void, onTeardown: @escaping () -> Void) {
        initialURL = url
        self.goal = goal
        self.onFailure = onFailure
        self.onClosed = onClosed
        self.onTeardown = onTeardown
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use init(url:goal:onFailure:onClosed:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = makeWebView(configuration)
        mainWebView = web
        install(web)
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
        ])
        progress.startAnimating()
        let bridge = NativeBrowserSession(cookieStore: configuration.websiteDataStore.httpCookieStore,
                                          goal: goal.rawValue)
        session = bridge
        bridge.start { [weak self] context, error in
            guard let self, !self.closed else { return }
            guard let context, error == nil else {
                self.progress.stopAnimating()
                self.onFailure("The sign-in browser could not start. Close and try again.")
                return
            }
            if !context.usesDefaultUserAgent { web.customUserAgent = context.userAgent }
            let defaultPath: String
            switch self.goal {
            case .login: defaultPath = "/signIn.html"
            case .oneTapLogin:
                guard let path = context.oneTapSignInPath else {
                    self.progress.stopAnimating()
                    self.onFailure("One-tap sign in is not available for this site.")
                    return
                }
                defaultPath = path
            case .telegramBind: defaultPath = "/setting#contact"
            default: defaultPath = "/"
            }
            let value = self.initialURL.isEmpty
                ? context.baseUrl + defaultPath
                : (self.initialURL.hasPrefix("/") && !self.initialURL.hasPrefix("//")
                   ? context.baseUrl + self.initialURL : self.initialURL)
            guard NativePlatform.shared.isTrustedBrowserUrl(url: value), let url = URL(string: value) else {
                self.progress.stopAnimating()
                self.onFailure("This address is not allowed in the sign-in browser.")
                return
            }
            web.load(URLRequest(url: url)) // seed and observer registration have completed
            self.poll = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    guard let self, !self.closed else { return }
                    if self.session?.goalReached() == true {
                        do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                        self.close(notify: true)
                        return
                    }
                }
            }
        }
    }

    private func makeWebView(_ configuration: WKWebViewConfiguration) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        return web
    }
    private func install(_ web: WKWebView) {
        web.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.topAnchor.constraint(equalTo: view.topAnchor),
            web.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    func close(notify: Bool) {
        guard !closed else { return }
        closed = true
        poll?.cancel()
        poll = nil
        for web in [mainWebView, popup].compactMap({ $0 }) {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
        }
        guard let session else {
            onTeardown()
            if notify { onClosed() }
            return
        }
        session.close { [self] error in
            // Restore/publish is part of close; retain the public presenter until
            // final drain completes, including an unchanged-cookie cancellation.
            onTeardown()
            if error != nil { onFailure("Cookies could not be synchronized. Please try again.") }
            if notify { onClosed() }
        }
    }
    func openExternalIfRequested(_ signal: Int) {
        guard signal != externalSignal else { return }
        externalSignal = signal
        guard goal == .manage, !closed, presentedViewController == nil,
              let url = (popup ?? mainWebView)?.url,
              NativePlatform.shared.isExternalBrowserUrl(url: url.absoluteString) else { return }
        present(SFSafariViewController(url: url), animated: true)
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = action.request.url else { decisionHandler(.cancel); return }
        let value = url.absoluteString
        if action.targetFrame?.isMainFrame == false {
            // Cloudflare's iframe needs HTTPS, but file/data/javascript navigation never does.
            decisionHandler(url.scheme == "https" && NativePlatform.shared.isExternalBrowserUrl(url: value)
                            ? .allow : .cancel)
        } else if NativePlatform.shared.isBrowserUrl(url: value, goal: goal.rawValue) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            // Redirects/scripts cannot open Safari. A user-tapped ordinary link may, with NO cookie injection.
            if action.navigationType == .linkActivated,
               NativePlatform.shared.isExternalBrowserUrl(url: value), presentedViewController == nil {
                present(SFSafariViewController(url: url), animated: true)
            }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimating()
        if goal == .oneTapLogin, webView === mainWebView, !triggeredOneTap,
           let url = webView.url?.absoluteString, let script = NativePlatform.shared.oneTapScript(url: url) {
            triggeredOneTap = true
            // Static, original site-owned script, only on the active site's exact one-tap page.
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }
    private func navigationFailed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        progress.stopAnimating()
        onFailure("The page could not load. Close and try again.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        progress.stopAnimating()
        onFailure("The browser stopped. Close and try again.")
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed, popup == nil,
              let source = action.sourceFrame.request.url?.absoluteString,
              NativePlatform.shared.isBrowserUrl(url: source, goal: goal.rawValue),
              let target = action.request.url?.absoluteString,
              NativePlatform.shared.isBrowserUrl(url: target, goal: goal.rawValue) else { return nil }
        // Retain WebKit's supplied configuration: OAuth postMessage needs the actual opener relationship.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let child = makeWebView(configuration)
        child.customUserAgent = webView.customUserAgent
        popup = child
        install(child)
        return child
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popup else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        popup = nil
    }
}

/// Ordinary external content; never shares or seeds the application's cookie store.
struct NativeExternalBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIViewController {
        guard NativePlatform.shared.isExternalBrowserUrl(url: url.absoluteString) else {
            let controller = UIViewController()
            let label = UILabel()
            label.text = "This address cannot be opened."
            label.textAlignment = .center
            label.numberOfLines = 0
            label.textColor = .label
            controller.view.backgroundColor = .systemBackground
            label.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: controller.view.widthAnchor, multiplier: 0.9)
            ])
            return controller
        }
        return SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
