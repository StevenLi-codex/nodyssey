import XCTest
import UIKit
final class NativeNavigationUITests: XCTestCase {
    @MainActor func testLightProfileCanvasExtendsBehindNativeTab() { verify(dark: false) }
    @MainActor func testDarkProfileCanvasExtendsBehindNativeTab() { verify(dark: true) }
    @MainActor func testSameHostProductionPresetMenuAndSheet() { verifyTheme(systemDark: false) }
    @MainActor func testSystemDarkProductionMenu() { verifyTheme(systemDark: true) }
    @MainActor private func verifyTheme(systemDark: Bool) {
        let app = XCUIApplication()
        app.launchArguments = systemDark ? ["--system-dark"] : []
        app.launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 20))
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 10))
        app.buttons["native.profile.settings"].tap()
        let titles = ["theme": "settings_theme_mode", "source": "settings_color_source", "preset": "settings_color_source_preset"]
        var mode = systemDark ? "SYSTEM" : "LIGHT"
        var preset = "twins"
        var saves = 0
        func control(_ role: String) -> XCUIElement { app.buttons[titles[role]!].firstMatch }
        func releaseHeldSave(_ name: String, controls: [XCUIElement]) {
            saves += 1
            let gate = app.staticTexts["theme70.saveGate"].firstMatch
            let heldValue = "\(saves)/\(saves - 1)"
            let held = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", heldValue), object: gate)
            XCTAssertEqual(XCTWaiter.wait(for: [held], timeout: 10), .completed, "Fixture save entered hold")
            for button in controls { XCTAssertFalse(button.isEnabled, "SettingsAction busy gate") }
            // A real second hit on the same disabled owner must not reopen the
            // menu or dispatch another write. No production action is injected.
            controls[0].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertEqual(gate.label, heldValue, "Duplicate settings request")
            for button in controls { XCTAssertFalse(button.isEnabled, "Held save must remain disabled") }
            let releaseTime = Date().timeIntervalSince1970
            print("THEME70_SAVE " + String(data: try! JSONSerialization.data(withJSONObject: ["name": name, "releaseTimestamp": releaseTime, "starts": saves], options: .sortedKeys), encoding: .utf8)!)
            app.buttons["theme70.release"].firstMatch.tap()
            let released = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(saves)/\(saves)"), object: gate)
            XCTAssertEqual(XCTWaiter.wait(for: [released], timeout: 10), .completed, "Fixture save released")
        }
        func inspect(_ name: String) {
            let state = app.staticTexts["theme70.state"].firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertEqual(state.label, mode + "/PRESET/" + preset)
            Thread.sleep(forTimeInterval: 2)
            let shot = app.screenshot() // One capture supplies swatches AND actual closed control glyphs.
            let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let image = shot.image.cgImage!
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            bytes.withUnsafeMutableBytes { data in
                let context = CGContext(data: data.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            let dark = mode == "DARK" || (mode == "SYSTEM" && systemDark)
            let lightPalette = ["twins": [143, 111, 0], "graphite": [53, 96, 110], "reimu": [188, 48, 56], "miku": [0, 128, 120]]
            let darkPalette = ["twins": [255, 216, 74], "graphite": [53, 96, 110], "reimu": [255, 179, 182], "miku": [83, 215, 206]]
            let expected = (dark ? darkPalette : lightPalette)[preset]!
            let scale = CGFloat(w) / app.frame.width
            for key in ["theme70.tint", "theme70.accent"] {
                let swatch = app.descendants(matching: .any)[key].firstMatch
                XCTAssertTrue(swatch.exists, app.debugDescription)
                guard swatch.exists else { continue }
                let index = (Int(swatch.frame.midY * scale) * w + Int(swatch.frame.midX * scale)) * 4
                let actual = Array(bytes[index..<index + 3]).map(Int.init)
                print("THEME70_SWATCH \(name) \(key) expected=\(expected) actual=\(actual)")
                XCTAssertLessThanOrEqual(zip(expected, actual).map { abs($0 - $1) }.max()!, 2, name + " " + key)
            }
            for role in ["theme", "source", "preset"] {
                let button = control(role)
                XCTAssertTrue(button.exists && button.isEnabled, app.debugDescription)
                let rect = button.frame
                var histogram: [Int: Int] = [:]
                for y in max(0, Int(rect.minY * scale))..<min(h, Int(rect.maxY * scale)) {
                    for x in max(0, Int(rect.minX * scale))..<min(w, Int(rect.maxX * scale)) {
                        let index = (y * w + x) * 4
                        let rgb = Array(bytes[index..<index + 3]).map(Int.init)
                        if rgb.max()! - rgb.min()! > 20 { histogram[(rgb[0] << 16) | (rgb[1] << 8) | rgb[2], default: 0] += 1 }
                    }
                }
                let dominant = histogram.max(by: { $0.value < $1.value }) ?? (key: 0, value: 0)
                let actual = [(dominant.key >> 16) & 255, (dominant.key >> 8) & 255, dominant.key & 255]
                let record: [String: Any] = ["name": name, "role": role, "preset": preset, "mode": mode, "timestamp": Date().timeIntervalSince1970,
                    "scheme": dark ? "dark" : "light", "expected": expected, "actual": actual, "count": dominant.value,
                    "label": button.label, "value": button.value as? String ?? "", "frame": [rect.minX, rect.minY, rect.width, rect.height]]
                print("THEME70_CONTROL " + String(data: try! JSONSerialization.data(withJSONObject: record, options: .sortedKeys), encoding: .utf8)!)
                XCTAssertGreaterThan(dominant.value, 20, name + " missing rendered value")
                XCTAssertLessThanOrEqual(zip(expected, actual).map { abs($0 - $1) }.max()!, 2, name + " " + role)
            }
        }
        func choose(_ role: String, _ target: String, _ newMode: String, _ newPreset: String, _ name: String) {
            let picker = control(role)
            XCTAssertTrue(picker.waitForExistence(timeout: 8), app.debugDescription)
            let oldValue = picker.value as? String ?? ""
            XCTAssertFalse(oldValue.isEmpty, "Accessible selected value missing")
            // Exercise the restored padded hit area, not only the text glyphs.
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1)).withOffset(CGVector(dx: 0, dy: -2)).tap()
            Thread.sleep(forTimeInterval: 1.2)
            print("THEME70_MENU " + String(data: try! JSONSerialization.data(withJSONObject: ["name": name, "role": role, "selected": oldValue, "timestamp": Date().timeIntervalSince1970], options: .sortedKeys), encoding: .utf8)!)
            let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-open-menu"; tree.lifetime = .keepAlways; add(tree)
            let option = app.buttons[target].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription); option.tap()
            releaseHeldSave(name, controls: [control(role)] + ["theme", "source", "preset"].filter { $0 != role }.map(control))
            mode = newMode; preset = newPreset
            let state = app.staticTexts["theme70.state"].firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", mode + "/PRESET/" + preset), object: state)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
            inspect(name)
        }
        let prefix = systemDark ? "system-dark" : "theme"
        inspect(prefix + "-push-initial")
        choose("preset", "settings_preset_graphite", mode, "graphite", prefix + "-push-graphite")
        choose("preset", "settings_preset_reimu", mode, "reimu", prefix + "-push-reimu")
        choose("preset", "settings_preset_miku", mode, "miku", prefix + "-push-miku")
        choose("theme", "settings_theme_dark", "DARK", preset, prefix + "-mode-dark")
        choose("theme", "settings_theme_light", "LIGHT", preset, prefix + "-mode-light")
        choose("theme", "settings_theme_system", "SYSTEM", preset, prefix + "-mode-system")
        choose("preset", "settings_preset_graphite", mode, "graphite", prefix + "-push-graphite-return")
        app.buttons["theme70.detail"].tap()
        XCTAssertTrue(app.staticTexts["destination"].waitForExistence(timeout: 8))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        inspect(prefix + "-push-after-detail")
        app.buttons["theme70.sheet"].tap()
        inspect(prefix + "-sheet-initial")
        choose("preset", "settings_preset_miku", mode, "miku", prefix + "-sheet-miku")
        choose("preset", "settings_preset_graphite", mode, "graphite", prefix + "-sheet-graphite")
        app.buttons["action_close"].firstMatch.tap()
        inspect(prefix + "-push-after-sheet")
        app.buttons["theme70.other"].tap()
        let language = app.buttons["settings_language"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 8))
        XCTAssertEqual(language.value as? String, "settings_language_en")
        language.tap()
        app.buttons["settings_language_system"].firstMatch.tap()
        releaseHeldSave(prefix + "-language-system", controls: [language])
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == YES", "settings_language_system"), object: language)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["theme70.language"].label, "SYSTEM")
        language.tap(); app.buttons["settings_language_en"].firstMatch.tap()
        releaseHeldSave(prefix + "-language-en", controls: [language])
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == YES", "settings_language_en"), object: language)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts["theme70.language"].label, "ENGLISH")
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
