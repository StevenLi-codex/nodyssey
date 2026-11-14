// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeMedia", platforms: [.macOS(.v14)], dependencies: [.package(path: "../NativeCore")], targets: [
    .target(name: "NativeMedia", dependencies: [.product(name: "NodysseyNativeCore", package: "NativeCore")], path: "Sources"),
    .testTarget(name: "NativeMediaTests", dependencies: ["NativeMedia"], path: "Tests")
])
