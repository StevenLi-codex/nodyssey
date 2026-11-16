import XCTest
import UIKit
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testLightProfileCanvasExtendsBehindNativeTab() { verify(dark: false) }
    @MainActor func testDarkProfileCanvasExtendsBehindNativeTab() { verify(dark: true) }
    @MainActor private func verify(dark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = dark ? ["--dark"] : []
        app.launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 20), app.debugDescription)
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 10), app.debugDescription)
        let mode = dark ? "dark" : "light"
        capture(app, mode + "-initial", dark)
        app.swipeUp()
        capture(app, mode + "-scrolled", dark)
        app.tabBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons.element(boundBy: 2).tap()
        capture(app, mode + "-return", dark)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String, _ dark: Bool) {
        let probe = app.descendants(matching: .any)["retention.geometry"]
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = probe.value as? String, let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return value["settled"] as? Bool == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed)
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let image = shot.image.cgImage!
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { bytes in
            let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let scale = CGFloat(w) / app.frame.width
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let offset = (Int(y * scale) * w + Int(x * scale)) * 4
            return Array(rgba[offset..<offset + 3]).map(Int.init)
        }
        // 8pt is outside the 16pt card inset and floating native tab pill.
        // These fixed strips cross the bottom safe-area boundary, not the glass itself.
        let reference = pixel(8, app.frame.height / 2)
        let samples = [110, 100, 90, 80, 70].map { delta -> [String: Any] in
            let y = app.frame.height - CGFloat(delta)
            let rgb = pixel(8, y)
            let difference = zip(reference, rgb).map { abs($0 - $1) }.max()!
            return ["x": 8, "y": y, "rgb": rgb, "difference": difference]
        }
        let text = probe.value as? String ?? "{}"
        let geometry = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let record: [String: Any] = ["name": name, "reference": reference, "samples": samples, "geometry": geometry,
                                   "tabFrame": NSStringFromCGRect(app.tabBars.firstMatch.frame),
                                   "settingsFrame": NSStringFromCGRect(app.buttons["native.profile.settings"].frame),
                                   "screen": NSStringFromCGRect(app.frame)]
        let json = String(data: try! JSONSerialization.data(withJSONObject: record, options: .sortedKeys), encoding: .utf8)!
        let evidence = XCTAttachment(string: json); evidence.name = name + "-metrics"; evidence.lifetime = .keepAlways; add(evidence)
        print("BACKGROUND " + json)
        XCTAssertEqual(reference[0], dark ? 9 : 242, accuracy: 2, "Canvas color was not exercised")
        for sample in samples {
            XCTAssertLessThanOrEqual(sample["difference"] as! Int, 2, "Profile canvas discontinuity: " + json)
        }
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(app.buttons["native.profile.settings"].isHittable)
    }
}
