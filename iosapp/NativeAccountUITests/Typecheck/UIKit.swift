// Compile-only UIKit signatures for the macOS CLT check. Never linked into the app.
import Foundation
public class UIImage {
    public init?(data: Data) { fatalError() }
    public func jpegData(compressionQuality: Double) -> Data? { fatalError() }
}
@MainActor public class UIPasteboard {
    public static let general = UIPasteboard()
    public var string: String?
}
@MainActor public class UIApplication {
    public static let shared = UIApplication()
    public func open(_ url: URL, options: [String: String], completionHandler: @escaping (Bool) -> Void) { fatalError() }
}
