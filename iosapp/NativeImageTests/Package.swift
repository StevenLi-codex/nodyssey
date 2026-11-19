// swift-tools-version: 6.0
import PackageDescription

// The runner stages shipping implementations, not a reimplementation.
let package = Package(
    name: "NativeImage",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NativeImage", path: "Sources"),
        .testTarget(name: "NativeImageTests", dependencies: ["NativeImage"], path: "Tests"),
    ],
    swiftLanguageModes: [.v5]
)
