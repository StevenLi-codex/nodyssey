import XCTest
final class NativeNavigationUITests: XCTestCase {
    @MainActor private func launch(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if large { app.launchArguments = ["--large-profile"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 20), app.debugDescription)
        return app
    }
    @MainActor private func tab(_ app: XCUIApplication, _ index: Int) { app.tabBars.buttons.element(boundBy: index).tap() }
    @MainActor private func visible(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        let rows = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).allElementsBoundByIndex
        return rows.first { $0.isHittable && $0.frame.minY > 240 && $0.frame.maxY < app.frame.height - 170 } ?? rows.first!
    }
    @MainActor private func back(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["destination"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    @MainActor func testHomeTabAndRouteReturnRetainsLoadedWindowAndRow() {
        let app = launch()
        for _ in 0..<3 { app.swipeUp() }
        let anchor = visible(app, "Post "); let title = anchor.label
        XCTAssertNotEqual(title, "Post 0")
        tab(app, 2); XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 8))
        tab(app, 0)
        XCTAssertTrue(app.staticTexts[title].isHittable, "Tab return lost \(title): " + app.debugDescription)
        app.staticTexts[title].tap(); back(app)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].isHittable, "Route return lost \(title): " + app.debugDescription)
        print("RETENTION home anchor=" + title + " " + app.staticTexts["requests"].label)
    }
    @MainActor private func geometry(_ app: XCUIApplication) -> [String: Any] {
        let value = app.descendants(matching: .any)["retention.geometry"].value as? String ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
    }
    @MainActor private func capture(_ app: XCUIApplication, _ anchor: XCUIElement, _ name: String) -> [String: Any] {
        var sample = geometry(app)
        sample["anchorLabel"] = anchor.label; sample["anchorY"] = anchor.frame.minY
        sample["anchorH"] = anchor.frame.height; sample["uptime"] = ProcessInfo.processInfo.systemUptime
        let text = String(data: try! JSONSerialization.data(withJSONObject: sample, options: .sortedKeys), encoding: .utf8)!
        let attachment = XCTAttachment(string: text); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("GEOMETRY " + name + " " + text)
        return sample
    }
    @MainActor private func settled(_ app: XCUIApplication, _ anchor: XCUIElement, _ name: String) -> [String: Any] {
        var previous: CGRect?; var stable = 0
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let rect = anchor.frame
            let idle = self.geometry(app)["settled"] as? Bool == true
            stable = idle && previous == rect ? stable + 1 : 0
            previous = rect
            return stable >= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed, "Layout did not quiesce for " + name)
        return capture(app, anchor, name)
    }
    @MainActor func testProfileTabAndRouteReturnAvoidsFreshNetworkFetch() {
        let app = launch(large: true); tab(app, 2)
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 8))
        let before = app.staticTexts["requests"].label
        XCTAssertTrue(before.hasPrefix("p1 "), before)
        app.swipeUp()
        app.swipeUp()
        XCTAssertFalse(app.staticTexts["Retained reader"].isHittable, "Fixture must actually scroll the production profile")
        let anchor = app.scrollViews.buttons.allElementsBoundByIndex.first { $0.isHittable && $0.frame.minY > 250 && $0.frame.maxY < app.frame.height - 180 }!
        let anchorLabel = anchor.label
        let anchorY = anchor.frame.minY
        _ = capture(app, anchor, "before-immediate")
        _ = settled(app, anchor, "before-settled")
        let settings = app.buttons["native.profile.settings"]
        tab(app, 0); tab(app, 2)
        XCTAssertTrue(app.buttons[anchorLabel].isHittable, "Profile tab return lost its visible directory anchor")
        _ = capture(app, app.buttons[anchorLabel], "tab-immediate")
        _ = settled(app, app.buttons[anchorLabel], "tab-settled")
        XCTAssertEqual(app.buttons[anchorLabel].frame.minY, anchorY, accuracy: 3, "Profile tab return changed scroll position")
        XCTAssertTrue(app.staticTexts["requests"].label.hasPrefix("p1 "))
        settings.tap(); back(app)
        XCTAssertTrue(app.buttons[anchorLabel].isHittable, "Profile route return lost its visible directory anchor")
        _ = capture(app, app.buttons[anchorLabel], "route-immediate")
        _ = settled(app, app.buttons[anchorLabel], "route-settled")
        XCTAssertEqual(app.buttons[anchorLabel].frame.minY, anchorY, accuracy: 3, "Profile route return changed scroll position")
        print("RETENTION profile anchor=" + anchorLabel + " before=\(anchorY) after=\(app.buttons[anchorLabel].frame.minY)")
        XCTAssertTrue(app.staticTexts["requests"].label.hasPrefix("p1 "), app.staticTexts["requests"].label)
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        XCTAssertTrue(app.staticTexts["Retained reader"].isHittable)
        print("RETENTION profile " + app.staticTexts["requests"].label)
    }
    @MainActor func testNotificationsTabAndRouteReturnRetainsScrollAndFreshObserver() {
        let app = launch(); tab(app, 1)
        XCTAssertTrue(app.staticTexts["Notification 0"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<3 { app.swipeUp() }
        let title = visible(app, "Notification ").label
        XCTAssertNotEqual(title, "Notification 0")
        tab(app, 2); tab(app, 1)
        XCTAssertTrue(app.staticTexts[title].isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts["requests"].label.contains(" n1 "), app.staticTexts["requests"].label)
        app.staticTexts[title].tap(); back(app)
        XCTAssertTrue(app.staticTexts[title].isHittable, app.debugDescription)
        print("RETENTION notifications anchor=" + title + " " + app.staticTexts["requests"].label)
    }
    @MainActor func testIdentityRevocationRemovesPrivateRootsAndLateCallbacks() {
        let app = launch(); tab(app, 2)
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 8))
        app.buttons["revoke"].tap()
        XCTAssertTrue(app.buttons["native.profile.signin"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Retained reader"].exists)
        tab(app, 1)
        XCTAssertFalse(app.staticTexts["Notification 0"].exists)
    }
}
