// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NativeFoundationTests",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../NativeCore")],
    targets: [
        .target(name: "NativeFoundation", dependencies: [.product(name: "NodysseyNativeCore", package: "NativeCore")], path: "Sources"),
        .testTarget(name: "NativeFoundationTests", dependencies: ["NativeFoundation"], path: "Tests")
    ]
)
