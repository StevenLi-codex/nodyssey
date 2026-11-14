import CoreGraphics
import NodysseyShell
import UIKit
import XCTest

/// Supplementary host comparison, not a replacement for WebKitSvgRasterizerTest.
final class NativeSvgHostTests: XCTestCase {
    @MainActor
    func testSameKotlinRasterizerPreservesPixels() async throws {
        // A hosted unit-test bundle must execute inside the real application, not a test runner app.
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.nodyssey")
        XCTAssertTrue(Thread.isMainThread)
        let probe = NativeSvgVerification()
        let completed = expectation(description: "Same Kotlin SVG pipeline completed after cleanup")
        let cleaned = expectation(description: "Pipeline cleanup completed, including watchdog cancellation")
        var png: Data?
        probe.start { data in
            XCTAssertTrue(Thread.isMainThread)
            png = data as Data?
            completed.fulfill()
            cleaned.fulfill()
        }
        // Same outer watchdog as the standalone test. This does NOT change the production 8s
        // capture+worker deadline. Async fulfillment yields Main to the application's run loop.
        await fulfillment(of: [completed], timeout: 15.0)
        probe.cancel()
        // Like iosTest's finally block, allow only cleanup to finish after a watchdog failure.
        // The first failed expectation stays failed even if cancellation now produces a callback.
        await fulfillment(of: [cleaned], timeout: 3.0)
        let bytes = try XCTUnwrap(png, "SVG raster returned null; inspect [svg-raster] stages")
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        let image = try XCTUnwrap(UIImage(data: bytes)?.cgImage)
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)

        // Match the native test's unflipped RGBA premultiplied-last bitmap and exact samples.
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        func channel(_ x: Int, _ y: Int, _ c: Int) -> UInt8 {
            pixels[(y * 16 + x) * 4 + c]
        }
        XCTAssertEqual(channel(2, 2, 0), 255, "top-left red must not be vertically flipped")
        XCTAssertEqual(channel(2, 13, 2), 255, "bottom-left blue must not be vertically flipped")
        XCTAssertEqual(channel(2, 2, 3), 255, "red sample must be opaque")
        XCTAssertEqual(channel(2, 13, 3), 255, "blue sample must be opaque")
        XCTAssertEqual(channel(13, 2, 3), 0, "transparent pixels must keep their alpha")
        XCTAssertEqual(channel(13, 13, 3), 0, "transparent pixels must keep their alpha")
    }
}
