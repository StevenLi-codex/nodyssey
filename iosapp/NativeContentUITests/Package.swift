// swift-tools-version: 6.0
import PackageDescription
import Foundation
// Runner-only IRGen workaround for unchanged NativeEditorScreens under Swift 6.
// Remove when the composition toolchain compiles this target without crashing.
let compositionSettings: [SwiftSetting] = ProcessInfo.processInfo.environment["CONTENT_COMPOSITION"] == "1"
    ? [.swiftLanguageMode(.v5)] : []
let package = Package(name: "NativeContentState", platforms: [.macOS(.v14)], targets: [
    .target(name: "NodysseyNativeCore", path: "Core"),
    .target(name: "NativeContentState", dependencies: ["NodysseyNativeCore"], path: "Sources", swiftSettings: compositionSettings),
    .testTarget(name: "ContentTests", dependencies: ["NativeContentState", "NodysseyNativeCore"], path: "Tests"),
])
