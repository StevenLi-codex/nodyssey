// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "NativeEditor", platforms: [.macOS(.v14)], dependencies: [.package(path: "../NativeCore")], targets: [.target(name: "NativeEditor", dependencies: [.product(name: "NodysseyNativeCore", package: "NativeCore")], path: "Sources"), .testTarget(name: "NativeEditorTests", dependencies: ["NativeEditor"], path: "Tests")])
