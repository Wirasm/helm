import XCTest

@testable import Helm

/// The canvas's two sources and the seam between them. No window and no WebKit:
/// everything here is the model deciding what the pane is showing.
@MainActor
final class CanvasModelTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-canvas-\(UUID().uuidString).md")
        try "# plan".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func page(of model: CanvasModel) -> CanvasModel.Page? {
        if case let .url(page) = model.showing { page } else { nil }
    }

    // MARK: - The persistence seam

    func testAURLSourceExposesNoFilePath() {
        // WorkspaceModel.saveContext persists `fileURL?.path` into a field read
        // back through URL(fileURLWithPath:). A URL leaking into it would be
        // restored as a garbage file path on the next workspace switch.
        let model = CanvasModel()
        model.open(file)
        XCTAssertEqual(model.fileURL, file)

        model.openURL(URL(string: "https://example.com/dashboard")!)
        XCTAssertNil(model.fileURL, "a URL canvas must persist no path at all")
        XCTAssertTrue(model.isOpen, "it is still an open canvas, just not a file one")
    }

    // MARK: - ⌘L

    func testFocusAddressOpensAnEmptyPageOnAClosedCanvas() {
        let model = CanvasModel()
        model.focusAddress()

        XCTAssertNil(page(of: model)?.url, "nothing is loaded until an address is committed")
        XCTAssertEqual(page(of: model)?.address, "")
        XCTAssertEqual(model.addressFocus, 1)
    }

    func testFocusAddressKeepsThePageItIsAlreadyShowing() {
        // ⌘L on an open canvas is "edit this address", not "start over" — and the
        // counter still rises so the field re-focuses.
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.focusAddress()

        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(model.addressFocus, 1)
    }

    func testFocusAddressReplacesAFileSource() {
        let model = CanvasModel()
        model.open(file)
        model.focusAddress()

        XCTAssertNotNil(page(of: model), "single pane: the URL source takes it over")
        XCTAssertNil(model.fileURL)
    }

    // MARK: - Committing an address

    func testSubmitLoadsAParseableAddress() {
        let model = CanvasModel()
        model.focusAddress()
        model.submitAddress("localhost:3000")

        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(page(of: model)?.address, "http://localhost:3000")
        XCTAssertNil(page(of: model)?.failure)
    }

    func testSubmitKeepsThePageAndSaysWhyWhenTheAddressIsRefused() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.submitAddress("ssh://root@evil.example")

        XCTAssertEqual(
            page(of: model)?.url?.absoluteString, "http://localhost:3000",
            "a typo must not blank the canvas")
        XCTAssertEqual(page(of: model)?.address, "ssh://root@evil.example")
        XCTAssertNotNil(page(of: model)?.failure, "a refusal is never silent")
    }

    func testSubmitIgnoresAFileSource() {
        let model = CanvasModel()
        model.open(file)
        model.submitAddress("localhost:3000")

        XCTAssertEqual(model.fileURL, file, "there is no address bar on a file canvas")
    }

    // MARK: - Loading again

    func testResubmittingTheSameAddressStillRetries() {
        // The ordinary case: the dev server was not up yet. The view loads on a
        // (url, generation) key, so an unchanged URL has to move the counter.
        let model = CanvasModel()
        model.focusAddress()
        model.submitAddress("localhost:3000")
        let first = page(of: model)?.generation
        model.submitAddress("localhost:3000")

        XCTAssertEqual(page(of: model)?.generation, (first ?? 0) + 1)
    }

    func testReloadBumpsTheCounterAndClearsTheFailure() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("Could not connect to the server.")
        let before = page(of: model)?.generation

        model.reloadPage()

        XCTAssertEqual(page(of: model)?.generation, (before ?? 0) + 1)
        XCTAssertNil(page(of: model)?.failure)
    }

    func testReloadDoesNothingWithNothingLoaded() {
        let model = CanvasModel()
        model.focusAddress()
        model.reloadPage()

        XCTAssertEqual(page(of: model)?.generation, 0)
    }

    // MARK: - What the page reports back

    func testNavigationFollowsTheAddressFieldAndClearsTheFailure() {
        // A link click has to move the field, or reload would reload something
        // other than what is on screen.
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("stale")
        let before = page(of: model)?.generation

        model.pageDidNavigate(to: URL(string: "http://localhost:3000/about")!)

        XCTAssertEqual(page(of: model)?.address, "http://localhost:3000/about")
        XCTAssertEqual(page(of: model)?.url?.absoluteString, "http://localhost:3000/about")
        XCTAssertNil(page(of: model)?.failure)
        XCTAssertEqual(
            page(of: model)?.generation, before,
            "reporting where the page went must not ask the view to load it again")
    }

    func testFailureIsHeldOnThePage() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.pageDidFail("Could not connect to the server.")

        XCTAssertEqual(page(of: model)?.failure, "Could not connect to the server.")
        XCTAssertEqual(
            page(of: model)?.url?.absoluteString, "http://localhost:3000",
            "the address stays so reload can retry it")
    }

    func testAFileSourceIgnoresPageCallbacks() {
        let model = CanvasModel()
        model.open(file)
        model.pageDidFail("not mine")
        model.pageDidNavigate(to: URL(string: "http://example.com")!)

        XCTAssertEqual(model.fileURL, file)
    }

    // MARK: - Closing

    func testCloseEmptiesTheCanvasFromEitherSource() {
        let model = CanvasModel()
        model.openURL(URL(string: "http://localhost:3000")!)
        model.close()
        XCTAssertFalse(model.isOpen)

        model.open(file)
        model.close()
        XCTAssertFalse(model.isOpen)
    }
}
