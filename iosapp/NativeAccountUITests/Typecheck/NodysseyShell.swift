// Compile-only Objective-C export shape; no simulated transport behavior.
public class NativeRequest { public func cancel() { fatalError() } }
public class NativePlatformContext { public var oneTapSignInPath: String? { fatalError() } }
@MainActor public class NativePlatform {
    public static let shared = NativePlatform()
    public func ready(completion: @escaping (NativePlatformContext?, String?) -> Void) -> NativeRequest { fatalError() }
}
