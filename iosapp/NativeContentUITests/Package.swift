// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeContentState", platforms: [.macOS(.v14)], targets: [
    .target(name: "NodysseyNativeCore", path: "Core"),
    .target(name: "NativeContentState", dependencies: ["NodysseyNativeCore"], path: "Sources"),
    .testTarget(name: "ContentTests", dependencies: ["NativeContentState", "NodysseyNativeCore"], path: "Tests"),
])
