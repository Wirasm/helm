import XCTest

@testable import Helm

/// The browser pane on the bench: one pane per bench, persisted, and offered — it never takes
/// the keyboard from the pane the operator is typing in.
@MainActor
final class BrowserPaneBenchTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-browser-pane")

    /// A bench root nothing runs a browser in, so no pane here can reach the operator's live
    /// `~/.bench` browser — and a link a test opens cannot open in it.
    private let benchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("helm-browser-pane-\(UUID().uuidString)")

    private func mounted() -> WorkbenchModel {
        let root = benchRoot
        let model = WorkbenchModel(
            terminals: TerminalManager(),
            makeBrowser: { BrowserPaneModel(environment: ["BENCH_DIR": root.path], home: root) })
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

    /// A ⌘-clicked http link (#376): the browser pane is offered, the keyboard stays in the
    /// terminal that was clicked, and the address reaches that pane's browser to open as a tab.
    /// No browser runs under this bench root, so it waits there until one does.
    func testAClickedLinkOffersTheBrowserAndHandsItTheAddress() throws {
        let model = mounted()
        let typing = try XCTUnwrap(model.bench?.focusedPane?.id)
        let link = try XCTUnwrap(URL(string: "http://localhost:3000"))

        // From the clicked terminal's own callback, which is where the click arrives.
        try XCTUnwrap(model.focusedTerminal)
            .terminalDidRequestOpenURL(link.absoluteString, kind: .unknown)

        let pane = try XCTUnwrap(model.bench?.panes.first { $0.content == .browser })
        XCTAssertEqual(model.bench?.focusedPane?.id, typing, "a link click must not seize")
        XCTAssertEqual(model.browser(for: pane).pendingLinks, [link])
    }

    /// The second click reuses the pane and queues behind the first, rather than opening a
    /// second browser pane or dropping the earlier link.
    func testASecondLinkGoesToTheSameBrowserPane() throws {
        let model = mounted()
        let first = try XCTUnwrap(URL(string: "http://localhost:3000"))
        let second = try XCTUnwrap(URL(string: "https://example.com/docs"))

        model.openLink(first)
        model.openLink(second)

        let browser = try XCTUnwrap(model.bench?.panes.first { $0.content == .browser })
        XCTAssertEqual(model.browser(for: browser).pendingLinks, [first, second])
        XCTAssertEqual(model.bench?.panes.filter { $0.content == .browser }.count, 1)
    }

    func testABrowserPaneSurvivesARestart() throws {
        let bench = Workbench(panes: [
            Pane(content: .terminal()), Pane(content: .browser),
        ])
        let decoded = try JSONDecoder().decode(
            Workbench.self, from: JSONEncoder().encode(bench))
        XCTAssertEqual(decoded.panes.map(\.content).last, .browser)
    }

    /// The real browser kind, not a fake: closing the workspace lets the view onto the browser go
    /// (PR 3a of #354 — it used to be left open until an unmount), and the next pane onto the
    /// browser gets a fresh connection.
    func testClosingTheWorkspaceLetsTheBrowserViewGo() throws {
        let model = mounted()
        let id = try XCTUnwrap(model.offerBrowser())
        let pane = try XCTUnwrap(model.bench?.pane(id))
        let view = model.browser(for: pane)

        model.closeWorkspace(workspace)
        model.activate(workspacePath: workspace)

        XCTAssertNotIdentical(model.browser(for: pane), view)
    }
}
