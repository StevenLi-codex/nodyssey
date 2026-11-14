// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Command Line Tools omit XCTest/Testing; full Xcode uses its bundled Testing.
let sourceTesting = ProcessInfo.processInfo.environment["NATIVE_CORE_TESTING_FROM_SOURCE"] == "1"

let package = Package(
    name: "NativeCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "NodysseyNativeCore", targets: ["NodysseyNativeCore"])],
    dependencies: sourceTesting ? [.package(url: "https://github.com/swiftlang/swift-testing.git", revision: "18c42c19cac3fafd61cab1156d4088664b7424ae")] : [],
    targets: [
        .target(name: "NodysseyNativeCore"),
        .testTarget(name: "NodysseyNativeCoreTests", dependencies: [.target(name: "NodysseyNativeCore")] + (sourceTesting ? [.product(name: "Testing", package: "swift-testing")] : [])),
    ]
)
