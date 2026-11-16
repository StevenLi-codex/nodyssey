import XCTest
final class NativeNavigationUITests: XCTestCase {
    @MainActor private func launch(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (large ? ["--large-profile"] : [])
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
    @MainActor private func control(_ app: XCUIApplication, _ action: String) {
        app.buttons["control"].tap(); app.buttons[action].tap()
    }
    @MainActor private func screenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @MainActor private func assertPosition(_ app: XCUIApplication, _ title: String, _ before: [String: Any], _ name: String) {
        let after = settled(app, app.staticTexts[title], name)
        XCTAssertEqual(after["owner"] as? String, before["owner"] as? String, "UIKit list owner changed")
        XCTAssertEqual((after["offsetY"] as? NSNumber)?.doubleValue ?? -9999, (before["offsetY"] as? NSNumber)?.doubleValue ?? 9999, accuracy: 3, name)
        XCTAssertEqual((after["anchorY"] as? NSNumber)?.doubleValue ?? -9999, (before["anchorY"] as? NSNumber)?.doubleValue ?? 9999, accuracy: 3, name)
        XCTAssertTrue(app.staticTexts[title].isHittable)
    }
    @MainActor private func partialScroll(_ app: XCUIApplication) {
        for _ in 0..<2 { app.swipeUp() }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.543)))
        let g = geometry(app); let top = (g["viewportY"] as? NSNumber)?.doubleValue ?? 0
        let partial = app.cells.allElementsBoundByIndex.contains { $0.frame.minY < top && $0.frame.maxY > top }
        print("PARTIAL top=\(top) cells=" + app.cells.allElementsBoundByIndex.map { "\($0.frame)" }.joined(separator: ";"))
        XCTAssertTrue(partial, "Must begin with a partially clipped row")
    }
    @MainActor func testRapidTabsEqualAndDifferentEmissionsKeepExactHomeOffset() {
        let app = launch(); partialScroll(app)
        let title = visible(app, "Post ").label
        let before = settled(app, app.staticTexts[title], "home-before")
        screenshot(app, "home-before")
        for _ in 0..<4 { tab(app, 1); tab(app, 0) }
        assertPosition(app, title, before, "home-rapid-tabs")
        for action in ["Same", "Change", "Change", "Same"] {
            control(app, action); assertPosition(app, title, before, "home-" + action)
        }
        tab(app, 1); control(app, "Change"); control(app, "Same"); tab(app, 0)
        assertPosition(app, title, before, "home-background-update")
        XCTAssertTrue(app.staticTexts["requests"].label.contains(" n1 f1"), app.staticTexts["requests"].label)
        screenshot(app, "home-after")
    }
    @MainActor func testRapidTabsEqualAndDifferentEmissionsKeepExactNotificationOffset() {
        let app = launch(); tab(app, 1)
        XCTAssertTrue(app.staticTexts["Notification 0"].waitForExistence(timeout: 8))
        partialScroll(app)
        let title = visible(app, "Notification ").label
        let before = settled(app, app.staticTexts[title], "notifications-before")
        screenshot(app, "notifications-before")
        for _ in 0..<4 { tab(app, 0); tab(app, 1) }
        assertPosition(app, title, before, "notifications-rapid-tabs")
        for action in ["Same", "Change", "Change", "Same"] {
            control(app, action); assertPosition(app, title, before, "notifications-" + action)
        }
        XCTAssertTrue(app.staticTexts["requests"].label.contains(" n1 f1"), app.staticTexts["requests"].label)
        screenshot(app, "notifications-after")
    }
    @MainActor func testNotificationHeldLoadingEmptyCacheAndFailureRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["--hold-notifications", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 20)); tab(app, 1)
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Notification 0"].exists)
        screenshot(app, "notifications-held-loading")
        control(app, "Empty")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        tab(app, 0); tab(app, 1)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["requests"].label.contains(" n1 f1"))
        control(app, "Fail")
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.staticTexts["Notification 0"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["requests"].label.contains(" n2 f1"), app.staticTexts["requests"].label)
        app.buttons["revoke"].tap(); control(app, "Late")
        XCTAssertFalse(app.staticTexts["Notification 0"].exists)
        tab(app, 0); tab(app, 1)
        XCTAssertFalse(app.staticTexts["Notification 0"].exists)
        screenshot(app, "notifications-revoked-late")
    }
    @MainActor func testExplicitPageAndBoardReplacementWithoutSubtreeID() {
        let app = launch()
        let rail = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "of 20")).firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5), app.debugDescription); rail.tap()
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("10")
        app.buttons["Go"].tap()
        XCTAssertTrue(app.staticTexts["Post 90"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Post 90"].isHittable)
        XCTAssertTrue(app.staticTexts["requests"].label.contains("f2"))
        screenshot(app, "page-ten")
        app.buttons["Board B"].tap()
        XCTAssertTrue(app.staticTexts["BoardB 0"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["BoardB 0"].isHittable)
        app.buttons["All boards"].tap()
        XCTAssertTrue(app.staticTexts["Post 90"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Post 90"].isHittable)
        let title = visible(app, "Post ").label
        let before = settled(app, app.staticTexts[title], "board-restored")
        tab(app, 1); tab(app, 0)
        assertPosition(app, title, before, "board-return")
        XCTAssertTrue(app.staticTexts["requests"].label.contains("f4"), app.staticTexts["requests"].label)
        screenshot(app, "board-restored")
    }
    @MainActor func testMissingAnchorHiddenCompletionAndPageGeometryCanAdvance() {
        let app = XCUIApplication()
        app.launchArguments = ["--anchor-probe", "--hold-feed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 15))
        app.buttons["Hide feed"].tap()
        control(app, "Release")
        XCTAssertTrue(app.staticTexts["Hidden feed"].exists)
        app.buttons["Hide feed"].tap()
        XCTAssertTrue(app.staticTexts["Post 30"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Post 30"].isHittable)
        app.swipeUp(); app.swipeUp()
        XCTAssertNotEqual(app.staticTexts["observed-page"].label, "observed 0", app.debugDescription)
        XCTAssertNotEqual(app.staticTexts["observed-page"].label, "observed 4", "Missing anchor must not freeze viewport page")
        app.buttons["Page 10"].tap(); app.buttons["Hide feed"].tap()
        control(app, "Release"); app.buttons["Hide feed"].tap()
        XCTAssertTrue(app.staticTexts["Post 90"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Post 90"].isHittable, app.debugDescription)
        app.swipeUp(); app.swipeUp()
        XCTAssertNotEqual(app.staticTexts["observed-page"].label, "observed 10")
        screenshot(app, "missing-anchor-page-advanced")
    }
    @MainActor func testStaleNotificationReturnKeepsRowsWhileRefreshHeld() {
        let app = launch(); tab(app, 1)
        XCTAssertTrue(app.staticTexts["Notification 0"].waitForExistence(timeout: 8)); partialScroll(app)
        let title = visible(app, "Notification ").label
        let before = settled(app, app.staticTexts[title], "ttl-before")
        tab(app, 0)
        // Real production 60-second monotonic TTL; no test clock/hook.
        Thread.sleep(forTimeInterval: 62)
        tab(app, 1)
        XCTAssertTrue(app.staticTexts["requests"].label.contains("r1"), app.staticTexts["requests"].label)
        XCTAssertTrue(app.staticTexts[title].isHittable)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists)
        assertPosition(app, title, before, "ttl-refresh-held")
        control(app, "Change")
        assertPosition(app, title, before, "ttl-refreshed")
        screenshot(app, "ttl-old-rows-return")
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
