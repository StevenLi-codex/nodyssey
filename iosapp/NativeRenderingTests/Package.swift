// swift-tools-version: 6.0
import PackageDescription

// run-tests.sh stages the actual production source here; no second implementation.
let package = Package(
    name: "NativeRendering",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NativeRendering", targets: ["NativeRendering"])],
    targets: [
        .target(name: "NativeRendering", path: "Sources"),
        .testTarget(name: "NativeRenderingTests", dependencies: ["NativeRendering"], path: "Tests"),
    ]
)
