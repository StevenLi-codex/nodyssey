// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AccountBehavior", platforms: [.macOS(.v13)], dependencies: [.package(path: "../NativeCore")], targets: [
 .target(name: "AccountBehavior", dependencies: [.product(name: "NodysseyNativeCore", package: "NativeCore")], path: "Sources"),
 .testTarget(name: "AccountBehaviorTests", dependencies: ["AccountBehavior"], path: "Tests")
])
