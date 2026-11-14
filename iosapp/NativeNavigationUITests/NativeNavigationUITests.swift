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
        selectTab("notifications", route: "Notifications")
        selectTab("home", route: "PostList")
    }

    // Catches a shared NavigationPath, or a path discarded on tab changes.
    // Settings is a deterministic local route: this must work with a failed feed.
    func testSettingsStackSurvivesSwitchingToOtherTabRoots() {
        selectTab("profile", route: "Profile")
        tap("native.profile.settings")
        assertScreen("Settings")

        selectTab("home", route: "PostList")
        assertNotHittable("native.screen.Settings")
        selectTab("notifications", route: "Notifications")
        assertNotHittable("native.screen.Settings")
        selectTab("profile", route: "Settings")
        selectTab("home", route: "PostList")
        selectTab("profile", route: "Settings")
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
        tap("native.tab.\(tab)", file: file, line: line)
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
        assertHittable("native.screen.\(route)", file: file, line: line)
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
