import XCTest

/// Guest acceptance against the real app/bridge, never a preview or mocked graph.
/// Run on a dedicated, freshly erased simulator; no authentication is performed.
final class NativeNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        // A fresh install may show onboarding. Complete the real user action,
        // not a launch-argument route or a direct settings-store write.
        let home = element("native.tab.home")
        let onboardingContinue = element("native.onboarding.continue")
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in home.isHittable || onboardingContinue.isHittable },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                       "Neither native tabs nor the real onboarding action became available")
        if onboardingContinue.isHittable {
            onboardingContinue.tap()
        }
        assertHittable("native.tab.home")
        XCTAssertTrue(element("native.root").waitForExistence(timeout: 10))
        selectTab("home", route: "PostList")
    }

    override func tearDownWithError() throws {
        if let app, testRun?.hasSucceeded == false {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Guest navigation failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Guest navigation accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        app?.terminate()
        app = nil
    }

    // Catches a tab that changes selection but fails to change its routed content.
    func testGuestCanRoundTripAllTabs() {
        selectTab("notifications", route: "Notifications")
        selectTab("profile", route: "Profile")
        assertHittable("native.profile.signin") // Fail rather than test a signed-in account.
        selectTab("home", route: "PostList")
        assertNotHittable("native.profile.signin")
        assertNotHittable("native.profile.settings")
        selectTab("notifications", route: "Notifications")
        assertNotHittable("native.profile.signin")
        assertNotHittable("native.profile.settings")
        selectTab("profile", route: "Profile")
        selectTab("home", route: "PostList")
    }

    // Catches a shared NavigationPath, or a path discarded on tab changes.
    // Settings is a deterministic local route: this must work with a failed feed.
    func testSettingsStackSurvivesSwitchingToOtherTabRoots() {
        selectTab("profile", route: "Profile")
        tap("native.profile.settings")
        assertScreen("Settings")

        exerciseSettingsChildAndBack()
        selectTab("home", route: "PostList")
        assertSettingsInactive()
        selectTab("notifications", route: "Notifications")
        assertSettingsInactive()
        selectTab("profile", route: "Settings")
        selectTab("home", route: "PostList")
        selectTab("profile", route: "Settings")
        exerciseSettingsChildAndBack()
    }

    // Catches a sign-in presentation which cannot cancel, loses its origin,
    // leaves a blocking sheet behind, or cannot be opened a second time.
    func testGuestCanCancelSignInAndReopenWithoutLosingNavigation() {
        selectTab("profile", route: "Profile")
        openSignIn()
        cancelSignIn()
        // Reopening proves cancellation cleared presentation state.
        openSignIn()
        cancelSignIn()
        assertScreen("Profile")
        tap("native.profile.settings")
        assertScreen("Settings")
        selectTab("notifications", route: "Notifications")
        selectTab("home", route: "PostList")
        selectTab("profile", route: "Settings")
    }

    private func openSignIn() {
        tap("native.profile.signin")
        assertScreen("SignIn")
        assertHittable("native.signin.account")
        assertHittable("native.signin.password")
        // Do not type credentials or submit; only navigate and cancel.
    }

    private func cancelSignIn() {
        tap("native.signin.cancel")
        assertNotHittable("native.screen.SignIn")
        assertHittable("native.profile.signin")
    }

    private func selectTab(_ tab: String, route: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        let identifier = "native.tab.\(tab)"
        tap(identifier, file: file, line: line)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND selected == true"),
            object: app.tabBars.buttons.matching(identifier: identifier).firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed,
                       "Tab tap did not select: \(tab)", file: file, line: line)
        assertScreen(route, file: file, line: line)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        assertHittable(identifier, file: file, line: line)
        element(identifier).tap()
    }

    private func assertScreen(_ route: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        if route == "Profile" {
            // The iOS List marker can resolve to a non-hittable CollectionView
            // even when its guest rows are visible (CI 43565737701). A container
            // hit point is not the user's navigation action. Require BOTH the
            // routed screen and its real actions, never mere marker existence.
            XCTAssertTrue(element("native.screen.Profile").waitForExistence(timeout: 15),
                          "Profile route is missing", file: file, line: line)
            assertHittable("native.profile.signin", file: file, line: line)
            assertHittable("native.profile.settings", file: file, line: line)
        } else if route == "Settings" {
            // CI 43577393525: both failures resolved this to a full-screen
            // CollectionView; exact failure hierarchies and screenshots show
            // Settings, Theme/Language rows, Profile selected, no modal. Require
            // real child hit points, plus exerciseSettingsChildAndBack below.
            XCTAssertTrue(element("native.screen.Settings").waitForExistence(timeout: 15),
                          "Settings route is missing", file: file, line: line)
            assertElementHittable(settingsThemeButton, file: file, line: line)
            assertElementHittable(settingsLanguageButton, file: file, line: line)
        } else {
            assertHittable("native.screen.\(route)", file: file, line: line)
        }
    }

    // Settings currently has no action identifiers. Scope to its exact route and
    // the three shipped localized labels, not arbitrary app-wide text matches.
    private var settingsThemeButton: XCUIElement {
        element("native.screen.Settings").buttons.matching(
            NSPredicate(format: "label IN %@", ["Theme", "主题", "主題"])
        ).firstMatch
    }
    private var settingsLanguageButton: XCUIElement {
        element("native.screen.Settings").buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
                        "Language,", "语言", "語言")
        ).firstMatch
    }
    private func assertSettingsInactive(file: StaticString = #filePath, line: UInt = #line) {
        for control in [settingsThemeButton, settingsLanguageButton] {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false OR hittable == false"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
                           "Inactive Settings action remains reachable", file: file, line: line)
        }
    }
    private func exerciseSettingsChildAndBack(file: StaticString = #filePath, line: UInt = #line) {
        assertElementHittable(settingsThemeButton, file: file, line: line)
        settingsThemeButton.tap()
        let theme = element("native.screen.ThemeSettings")
        XCTAssertTrue(theme.waitForExistence(timeout: 15), "Theme navigation did not push", file: file, line: line)
        let mode = theme.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Light or dark", "明暗")).firstMatch
        assertElementHittable(mode, file: file, line: line)
        let back = app.navigationBars.buttons.matching(identifier: "BackButton").firstMatch
        assertElementHittable(back, file: file, line: line)
        back.tap()
        assertScreen("Settings", file: file, line: line)
        assertNotHittable("native.screen.ThemeSettings", file: file, line: line)
    }
    private func assertElementHittable(_ control: XCUIElement,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "Expected reachable route-owned action: \(control)", file: file, line: line)
    }

    private func assertHittable(_ identifier: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element(identifier)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 15), .completed,
                       "Expected reachable UI: \(identifier)", file: file, line: line)
    }

    private func assertNotHittable(_ identifier: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"),
            object: element(identifier)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed,
                       "Inactive route still intercepts interaction: \(identifier)",
                       file: file, line: line)
    }
}
