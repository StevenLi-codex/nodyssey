import XCTest
import UIKit
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testLightProfileCanvasExtendsBehindNativeTab() { verify(dark: false) }
    @MainActor func testDarkProfileCanvasExtendsBehindNativeTab() { verify(dark: true) }
    @MainActor func testSameHostProductionPresetMenuAndSheet() {
        let app = XCUIApplication(); app.launch();
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 20))
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 10))
        app.buttons["native.profile.settings"].tap()
        func inspect(_ id: String, _ name: String) {
            let state = app.staticTexts["theme70.state"].firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(state.label, "LIGHT/PRESET/" + id)
            Thread.sleep(forTimeInterval: 2)
            let shot = app.screenshot()
            let attachment = XCTAttachment(screenshot: shot); attachment.name = name + "-swatches"; attachment.lifetime = .keepAlways; add(attachment)
            let image = shot.image.cgImage!
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let expected = ["twins": [143, 111, 0], "graphite": [53, 96, 110], "reimu": [188, 48, 56], "miku": [0, 128, 120]][id]!
            for key in ["theme70.tint", "theme70.accent"] {
                let swatch = app.descendants(matching: .any)[key].firstMatch
                XCTAssertTrue(swatch.exists, app.debugDescription)
                guard swatch.exists else { continue }
                let scale = CGFloat(w) / app.frame.width
                let index = (Int(swatch.frame.midY * scale) * w + Int(swatch.frame.midX * scale)) * 4
                let actual = Array(bytes[index..<index + 3]).map(Int.init)
                print("THEME70_SWATCH \(name) \(key) expected=\(expected) actual=\(actual)")
                XCTAssertLessThanOrEqual(zip(expected, actual).map { abs($0 - $1) }.max()!, 2, name + " " + key)
            }
        }
        func choose(_ current: String, _ target: String, _ id: String, _ name: String) {
            let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", current)).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
            picker.tap()
            let option = app.buttons[target].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription); option.tap()
            let state = app.staticTexts["theme70.state"].firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "LIGHT/PRESET/" + id), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
            inspect(id, name)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-tree"; tree.lifetime = .keepAlways; add(tree)
        }
        inspect("twins", "theme-push-initial")
        choose("settings_preset_twins", "settings_preset_graphite", "graphite", "theme-push-graphite")
        choose("settings_preset_graphite", "settings_preset_reimu", "reimu", "theme-push-reimu")
        choose("settings_preset_reimu", "settings_preset_miku", "miku", "theme-push-miku")
        choose("settings_preset_miku", "settings_preset_graphite", "graphite", "theme-push-graphite-return")
        app.buttons["theme70.sheet"].tap()
        inspect("graphite", "theme-sheet-initial")
        choose("settings_preset_graphite", "settings_preset_miku", "miku", "theme-sheet-miku")
        choose("settings_preset_miku", "settings_preset_graphite", "graphite", "theme-sheet-graphite")
    }
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
                                   "tabFrame": NSCoder.string(for:app.tabBars.firstMatch.frame),
                                   "settingsFrame": NSCoder.string(for:app.buttons["native.profile.settings"].frame),
                                   "screen": NSCoder.string(for:app.frame)]
        let json = String(data: try! JSONSerialization.data(withJSONObject: record, options: .sortedKeys), encoding: .utf8)!
        let evidence = XCTAttachment(string: json); evidence.name = name + "-metrics"; evidence.lifetime = .keepAlways; add(evidence)
        print("BACKGROUND " + json)
        let boundary = app.tabBars.firstMatch.frame.minY
        for x: CGFloat in [0, 1, 2, 4] {
            let above = pixel(x, boundary - 1), below = pixel(x, boundary + 1)
            let jump = zip(above, below).map { abs($0 - $1) }.max()!
            print("SEAM " + name + " x=\(x) y=\(boundary) above=\(above) below=\(below) jump=\(jump)")
            XCTAssertLessThanOrEqual(jump, 2, "Profile canvas discontinuity at native tab safe-area boundary: " + json)
        }
        XCTAssertEqual(app.tabBars.buttons.count, 3)
        XCTAssertTrue(app.buttons["native.profile.settings"].isHittable)
    }
}
