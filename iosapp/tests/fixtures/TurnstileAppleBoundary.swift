import Foundation
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// Only the Kotlin callback classifier boundary is replaced. WKWebView, frame
// metadata, navigation actions, script injection and delegate are real WebKit.
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
