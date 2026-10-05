import XCTest

final class RealStoreUITests: XCTestCase {
    @MainActor
    func testPhysicalTapOnBareCopiedArchonPath() {
        continueAfterFailure = false
        let app = launch()
        let chat = app.staticTexts["claude · ?"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 5) { tutorial.tap() }
        let message = app.links.matching(
            NSPredicate(format: "label ENDSWITH %@", "/reports/launch-queue.md")
        ).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        capture(app, "bare path before tap")
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.2)).tap()
        let heading = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "Archon run launch queue")
        ).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        capture(app, "bare path after tap")
        app.terminate()
    }

    @MainActor
    func testCopiedArchonMarkdownIsDiscoverableInPages() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.buttons["pages"].waitForExistence(timeout: 20))
        app.buttons["pages"].tap()
        XCTAssertTrue(app.staticTexts["20"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["reports/launch-queue"].exists)
        capture(app, "Pages newest twenty")
        let search = app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 5) { tutorial.tap() }
        search.typeText("launch-queue")
        capture(app, "Pages search")
        let page = app.staticTexts["reports/launch-queue"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        page.tap()
        let content = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "Archon run launch queue")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        capture(app, "Markdown opened from whole-store search")
        app.buttons["‹"].tap()
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testRelativeCopiedStorePathOpens() {
        continueAfterFailure = false
        let app = launch()
        let chat = app.staticTexts["claude · ?"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 5) { tutorial.tap() }
        capture(app, "relative path before tap")
        let link = app.links["reports/launch-queue.md"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let heading = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "Archon run launch queue")
        ).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        capture(app, "relative path after tap")
        app.buttons["‹"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertFalse(app.links["reports/not-listed.md"].exists)
        let html = app.links["Relative HTML"].firstMatch
        XCTAssertTrue(html.exists)
        html.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.webViews.staticTexts["HTML from benchd"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Sibling script loaded"].exists)
        app.buttons["‹"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testNewDocumentFromALaterReplyOpensWithoutLeavingTheChat() {
        continueAfterFailure = false
        let app = launch()
        let chat = app.staticTexts["claude · ?"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 5) { tutorial.tap() }
        XCTAssertTrue(app.links["reports/launch-queue.md"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.links["reports/later.md"].exists)
        let composer = app.textFields.firstMatch
        composer.tap()
        composer.typeText("create late document")
        app.buttons["↑"].tap()
        let link = app.links["reports/later.md"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let content = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "Created after chat opened")
        ).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        capture(app, "new document from a later reply")
        app.buttons["‹"].tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-benchURL", "tcp://127.0.0.1:52247", "-collapsed", "", "-collapsedPages", "",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name
        tree.lifetime = .keepAlways
        add(tree)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
