import XCTest

@testable import Helm

/// The browser pane on the bench: one pane per bench, persisted, and offered — it never takes
/// the keyboard from the pane the operator is typing in.
@MainActor
final class BrowserPaneBenchTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-browser-pane")

    private func mounted() -> WorkbenchModel {
        let model = WorkbenchModel(terminals: TerminalManager())
        model.activate(workspacePath: workspace)
        return model
    }

    func testOpeningTheBrowserLeavesTheKeyboardWhereItWas() throws {
        let model = mounted()
        let typing = try XCTUnwrap(model.bench?.focusedPane?.id)
        let focusedSlot = try XCTUnwrap(model.bench?.focusedSlot)

        let browser = try XCTUnwrap(model.offerBrowser())

        XCTAssertEqual(model.bench?.focusedPane?.id, typing, "an agent opening it must not seize")
        XCTAssertEqual(model.bench?.focusedSlot, focusedSlot)
        XCTAssertTrue(
            model.bench?.visiblePaneIDs.contains(browser) ?? false,
            "it arrives where it can be seen")
    }

    /// The case #353's review found: the browser a background tab in the slot the operator is
    /// typing in. Showing it there would make it the focused pane — a seizure by another name.
    func testReopeningABrowserTabBehindTheOperatorsPaneLeavesHimTyping() throws {
        let model = mounted()
        let browser = try XCTUnwrap(model.offerBrowser())
        let browserSlot = try XCTUnwrap(model.bench?.slot(for: browser)?.id)
        model.focus(browserSlot)
        let typing = try XCTUnwrap(model.newTerminal()).id  // a tab over the browser, focused
        XCTAssertEqual(model.bench?.focusedPane?.id, typing)

        XCTAssertEqual(model.offerBrowser(), browser)

        XCTAssertEqual(
            model.bench?.focusedPane?.id, typing,
            "an agent's openBrowser took the keyboard from the pane he was typing in")
    }

    func testThereIsOneBrowserPaneAndOpeningItAgainShowsThatOne() throws {
        let model = mounted()
        let first = try XCTUnwrap(model.offerBrowser())
        let second = try XCTUnwrap(model.offerBrowser())
        XCTAssertEqual(first, second)
        XCTAssertEqual(model.bench?.panes.filter { $0.content == .browser }.count, 1)
    }

    func testABrowserPaneSurvivesARestart() throws {
        let bench = Workbench(panes: [
            Pane(content: .terminal(face: .terminal)), Pane(content: .browser),
        ])
        let decoded = try JSONDecoder().decode(
            Workbench.self, from: JSONEncoder().encode(bench))
        XCTAssertEqual(decoded.panes.map(\.content).last, .browser)
    }
}
