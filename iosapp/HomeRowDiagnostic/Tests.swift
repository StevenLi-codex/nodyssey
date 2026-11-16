import XCTest
final class NativeNavigationUITests: XCTestCase {
    @MainActor private func launch(large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if large { app.launchArguments = ["--large"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Post 0"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.cells.containing(.staticText, identifier: title).firstMatch
    }
    @MainActor private func tap(_ app: XCUIApplication, _ cell: XCUIElement, x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cell.frame.minX + x, dy: cell.frame.minY + y)).tap()
    }
    @MainActor func testWholeCardBeforeScroll() {
        let app = launch()
        let cell = row(app, "Post 0")
        print("HOME69 initial hierarchy\n" + app.debugDescription)
        XCTAssertTrue(cell.exists)
        // Left card padding: visible card area, outside text/author control.
        tap(app, cell, x: 4, y: cell.frame.height / 2)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741001")
    }
    @MainActor func testHeaderWhitespaceBeforeScroll() {
        let app = launch(); let cell = row(app, "Post 0")
        tap(app, cell, x: cell.frame.width - 30, y: 18)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741001")
    }
    @MainActor func testTitleTrailingWhitespaceBeforeScroll() {
        let app = launch(); let cell = row(app, "Post 0")
        let title = app.staticTexts["Post 0"].frame
        tap(app, cell, x: cell.frame.width - 30, y: title.midY - cell.frame.minY)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741001")
    }
    @MainActor func testAuthorDoesNotOpenPost() {
        let app = launch()
        app.buttons.containing(.staticText, identifier: "Author 0").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["author-card"].waitForExistence(timeout: 5))
        app.buttons["Close card"].tap()
        XCTAssertEqual(app.staticTexts["event"].label, "Author:9007199254741101")
    }
    @MainActor func testPinnedPadding() {
        let app = launch(); let cell = row(app, "Post 2")
        tap(app, cell, x: 4, y: cell.frame.height / 2)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741003")
    }
    @MainActor func testAfterRepeatedScroll() {
        let app = launch()
        for _ in 0..<3 { app.swipeUp(); app.swipeDown() }
        let cell = row(app, "Post 0")
        XCTAssertTrue(cell.isHittable)
        tap(app, cell, x: 4, y: cell.frame.height / 2)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741001")
    }
    @MainActor func testLayoutProbe() {
        let app = launch()
        let author = app.staticTexts["Author 0"].frame
        let title = app.staticTexts["Post 0"].frame
        let long = app.staticTexts["Long title wraps across several lines with enough words to exercise the production row layout"].frame
        print("HOME69 layout author=\(author) title=\(title) long=\(long) row=\(row(app, "Post 0").frame) gap=\(title.minY-author.maxY)")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "home-layout"; attachment.lifetime = .keepAlways; add(attachment)
        // Disposable diagnostic only, not an appearance assertion in shipping tests.
        XCTAssertLessThan(title.minY - author.maxY, 16)
    }
    @MainActor func testLargeTypeCardPadding() {
        let app = launch(large: true); let cell = row(app, "Post 0")
        print("HOME69 large hierarchy\n" + app.debugDescription)
        tap(app, cell, x: 4, y: cell.frame.height / 2)
        XCTAssertEqual(app.staticTexts["event"].label, "PostDetail:9007199254741001")
    }
}
