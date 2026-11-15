// Test-only UIKit/Kotlin boundary signatures. The controller and WKWebView are real;
// cookies, transport and site callbacks are synthetic, and no URL is loaded.
import AppKit
import WebKit
import Foundation

@MainActor class UIViewController: NSObject {
    let view = NSView()
    var presentedViewController: UIViewController?
    init(nibName: String?, bundle: Bundle?) { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func viewDidLoad() {}
    func present(_ controller: UIViewController, animated: Bool) { presentedViewController = controller }
}
extension NSView {
    var backgroundColor: NSColor { get { .windowBackgroundColor } set {} }
}
extension NSColor { static var systemBackground: NSColor { .windowBackgroundColor } }
@MainActor final class UIActivityIndicatorView: NSView {
    enum Style { case medium }
    init(style: Style) { super.init(frame: .zero) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    func startAnimating() {}
    func stopAnimating() {}
}
@MainActor final class SFSafariViewController: UIViewController {
    init(url: URL) { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}
enum NativeBrowserGoal: String { case login, oneTapLogin, challenge, manage, telegramBind }
struct NativePlatformContext {
    var usesDefaultUserAgent = true
    var userAgent = "offline-fixture"
    var oneTapSignInPath: String? = nil
    var baseUrl = "https://offline.invalid"
}
@MainActor final class NativeBrowserSession {
    static var started: (() -> Void)?
    static var pendingClose: ((String?) -> Void)?
    init(cookieStore: WKHTTPCookieStore, goal: String) {}
    func start(completion: @escaping (NativePlatformContext?, String?) -> Void) {
        Self.started?()
        // Hold seed; no completion means no web.load and no live network.
    }
    func goalReached() -> Bool { false }
    func close(completion: @escaping (String?) -> Void) { Self.pendingClose = completion }
}
@MainActor final class NativePlatform {
    static let shared = NativePlatform()
    func isTrustedBrowserUrl(url: String) -> Bool { false }
    func isExternalBrowserUrl(url: String) -> Bool { false }
    func isBrowserUrl(url: String, goal: String) -> Bool { false }
    func oneTapScript(url: String) -> String? { nil }
}
