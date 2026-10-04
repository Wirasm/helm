import XCTest

/// Run with Pocket/test-store-links.py: a real isolated benchd serves the fixture transcript
/// and store. Tap the center of each current link frame: UITextView exposes both a wrapper
/// and a link, and its default accessibility hit point can land on the wrapper's edge.
final class StoreLinksUITests: XCTestCase {
    @MainActor
    func testDocumentsOpenAndBackReturnsToTheChat() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-benchURL", "tcp://127.0.0.1:52247", "-collapsed", ""]
        app.launch()
        let chat = app.staticTexts["claude · ?"]
        XCTAssertTrue(chat.waitForExistence(timeout: 20))
        chat.tap()
        // A fresh simulator shows iOS's keyboard tutorial over the app on its first field.
        let tutorial = app.buttons["Continue"]
        if tutorial.waitForExistence(timeout: 5) { tutorial.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))

        let markdown = app.links["Open markdown"].firstMatch
        XCTAssertTrue(markdown.waitForExistence(timeout: 10))
        markdown.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let document = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "Markdown from benchd")
        ).firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 10))
        capture("markdown")
        app.buttons["‹"].tap()
        XCTAssertTrue(markdown.waitForExistence(timeout: 5))

        let html = app.links["Open HTML"].firstMatch
        XCTAssertTrue(html.waitForExistence(timeout: 5))
        html.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.webViews.staticTexts["HTML from benchd"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Sibling script loaded"].exists)
        capture("html")
        app.buttons["‹"].tap()
        XCTAssertTrue(markdown.waitForExistence(timeout: 5))
        XCTAssertTrue(html.exists)
        XCTAssertTrue(app.buttons["screen"].exists, "back returned to the same chat")
        capture("chat after back")
        verifyPlainText(in: app)
        app.terminate()
    }

    @MainActor
    private func verifyPlainText(in app: XCUIApplication) {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let message = app.textViews.matching(
            NSPredicate(format: "value == %@", "Show the documents.")
        ).firstMatch
        let center = message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        message.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 5))
        let copyMessage = app.descendants(matching: .any)["Copy message"].firstMatch
        for _ in 0..<4 {
            if copyMessage.waitForExistence(timeout: 1) { break }
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "selection menu"
            tree.lifetime = .keepAlways
            add(tree)
            XCTAssertTrue(app.buttons["Forward"].exists)
            app.buttons["Forward"].tap()
        }
        XCTAssertTrue(copyMessage.exists)
    }

    @MainActor
    private func capture(_ name: String) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
    }
}
