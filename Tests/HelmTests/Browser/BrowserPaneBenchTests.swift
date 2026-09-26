import HelmWire
import XCTest

@testable import Helm

/// The browser pane on the bench, helm's half: a link reaches the shared browser through the one
/// browser pane, and the view onto it is let go with its pane. Where the pane lands and whether
/// it takes the keyboard are benchd's rules (`bench-doc`'s `placement.rs`).
@MainActor
final class BrowserPaneBenchTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-browser-pane")

    /// A bench root nothing runs a browser in, so no pane here can reach the operator's live
    /// `~/.bench` browser — and a link a test opens cannot open in it.
    private let benchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("helm-browser-pane-\(UUID().uuidString)")

    private func mounted() throws -> ToyRig {
        let root = benchRoot
        return try toyRig(workspace.value) { terminals, client in
            WorkbenchModel(
                terminals: terminals, agents: .blind,
                makeBrowser: {
                    BrowserPaneModel(environment: ["BENCH_DIR": root.path], home: root)
                },
                client: client)
        }
    }

    /// A ⌘-clicked http link (#376): a `pane/open` of the browser, and the address reaches that
    /// pane's browser to open as a tab. No browser runs under this bench root, so it waits there
    /// until one does.
    func testAClickedLinkOpensTheBrowserPaneAndHandsItTheAddress() throws {
        let rig = try mounted()
        let link = try XCTUnwrap(URL(string: "http://localhost:3000"))

        // From the clicked terminal's own callback, which is where the click arrives.
        try XCTUnwrap(rig.model.focusedTerminal)
            .terminalDidRequestOpenURL(link.absoluteString, kind: .unknown)

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/open")
        let pane = try XCTUnwrap(rig.model.bench?.panes.first { $0.content == .browser })
        XCTAssertEqual(rig.model.browser(for: pane).pendingLinks, [link])
    }

    /// The second click reuses the pane benchd answers with and queues behind the first, rather
    /// than dropping the earlier link.
    func testASecondLinkGoesToTheSameBrowserPane() throws {
        let rig = try mounted()
        let first = try XCTUnwrap(URL(string: "http://localhost:3000"))
        let second = try XCTUnwrap(URL(string: "https://example.com/docs"))

        rig.model.openLink(first)
        rig.model.openLink(second)

        let browser = try XCTUnwrap(rig.model.bench?.panes.first { $0.content == .browser })
        XCTAssertEqual(rig.model.browser(for: browser).pendingLinks, [first, second])
        XCTAssertEqual(rig.model.bench?.panes.filter { $0.content == .browser }.count, 1)
    }

    func testABrowserPaneCrossesTheDocument() throws {
        let bench = Workbench(panes: [Pane(content: .terminal()), Pane(content: .browser)])
        let crossed = try XCTUnwrap(Workbench(document: BenchDocument.Bench(bench)))
        XCTAssertEqual(crossed.panes.map(\.content).last, .browser)
    }

    /// The real browser kind, not a fake: closing the workspace lets the view onto the browser
    /// go, and the next pane onto the browser gets a fresh connection.
    func testClosingTheWorkspaceLetsTheBrowserViewGo() throws {
        let rig = try mounted()
        let id = try XCTUnwrap(rig.model.offerBrowser())
        let pane = try XCTUnwrap(rig.model.bench?.pane(id))
        let view = rig.model.browser(for: pane)

        rig.model.send(.workspaceClose(path: workspace.value), by: .operatorGesture)

        XCTAssertNil(rig.terminals.surfaces.existing(id, as: BrowserPaneModel.self))
        XCTAssertNotIdentical(rig.model.browser(for: pane), view)
    }
}
