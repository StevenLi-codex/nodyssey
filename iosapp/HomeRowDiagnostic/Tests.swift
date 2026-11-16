import XCTest
final class NativeNavigationUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launch()
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
    @MainActor func testProfileTabAndRouteReturnAvoidsFreshNetworkFetch() {
        let app = launch(); tab(app, 2)
        XCTAssertTrue(app.staticTexts["Retained reader"].waitForExistence(timeout: 8))
        let before = app.staticTexts["requests"].label
        XCTAssertTrue(before.hasPrefix("p1 "), before)
        app.swipeUp()
        let settings = app.buttons["native.profile.settings"]
        tab(app, 0); tab(app, 2)
        XCTAssertTrue(app.staticTexts["requests"].label.hasPrefix("p1 "))
        settings.tap(); back(app)
        XCTAssertTrue(app.staticTexts["requests"].label.hasPrefix("p1 "), app.staticTexts["requests"].label)
        app.swipeDown()
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
