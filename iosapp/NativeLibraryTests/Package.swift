// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeLibrary", platforms: [.macOS(.v14)], targets: [
    .target(name: "NodysseyNativeCore", path: "Core"),
    .target(name: "NativeLibrary", dependencies: ["NodysseyNativeCore"], path: "Sources"),
    .testTarget(name: "NativeLibraryTests", dependencies: ["NativeLibrary", "NodysseyNativeCore"], path: "Tests")
])
