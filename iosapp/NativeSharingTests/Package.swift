// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NativeSharingTests",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "Sharing", targets: ["Sharing"])],
    targets: [
        .target(name: "NodysseyNativeCore", path: "Core"),
        .target(name: "Sharing", dependencies: ["NodysseyNativeCore"], path: "Sources"),
        .testTarget(name: "SharingTests", dependencies: ["Sharing", "NodysseyNativeCore"], path: "Tests")
    ]
)
