import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// WebKit boundary values only; the coordinator under test is production Swift.
protocol WKNavigationDelegate {}
protocol WKScriptMessageHandler {}
class WKWebView: NSObject {}
class WKNavigation: NSObject {}
class WKUserContentController: NSObject {}
enum WKNavigationActionPolicy { case allow, cancel }
struct WKSecurityOrigin { let `protocol`: String; let host: String; let port: Int }
struct WKFrameInfo {
    let isMainFrame: Bool
    let request: URLRequest
    let securityOrigin: WKSecurityOrigin
}
struct WKNavigationAction {
    let request: URLRequest
    let targetFrame: WKFrameInfo?
}
struct WKScriptMessage {
    let webView: WKWebView?
    let name: String
    let frameInfo: WKFrameInfo
    let body: Any
}
class NativeRequest {}
struct NativePlatform {
    static let shared = NativePlatform()
    func turnstileMessageKind(kind: String, value: String) -> String {
        switch kind {
        case "token": return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unavailable" : "token"
        case "expired": return "expired"
        default: return "unavailable"
        }
    }
}
