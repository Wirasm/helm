import HelmWire
import XCTest

@testable import Helm

/// `LocalSink`: a verb applied to helm's own bench does what the old command did, and the focus
/// rule is benchd's — the keyboard moves only for the operator, or for an agent whose caller
/// says the operator asked.
///
/// These are the controls PR 4 deletes with the local path. Their Rust mirrors are
/// `bench-doc`'s placement and focus suites, which is what the daemon's sink is judged by.
@MainActor
final class LocalSinkTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-local-sink")

    private func mounted() -> WorkbenchModel {
        let model = WorkbenchModel(terminals: TerminalManager(), agents: .blind)
        model.activate(workspacePath: workspace)
        return model
    }

    /// Every verb that makes or shows a pane, three ways: the operator's gesture takes the
    /// keyboard, an agent's leaves it where it was, and an agent's that the operator asked for
    /// takes it. One table, so no verb can quietly get the rule wrong in one direction.
    func testTheKeyboardMovesOnlyForTheOperatorOrWhenHeAsked() throws {
        let verbs: [(String, (WorkbenchModel) throws -> BenchVerb)] = [
            ("terminal", { _ in .paneOpen(surface: .terminal(agent: nil)) }),
            ("canvas", { _ in .paneOpen(surface: .canvas(path: "/tmp/helm-local-sink/a.md")) }),
            ("split right", { _ in .paneSplit(direction: .right) }),
            ("split down", { _ in .paneSplit(direction: .down) }),
            (
                "a background tab",
                { model in
                    // A second tab in the focused slot, left behind the one holding the keyboard.
                    let hidden = try XCTUnwrap(
                        model.send(.paneOpen(surface: .terminal(agent: nil)), by: .agent()))
                    model.send(
                        .paneShow(try XCTUnwrap(model.bench?.panes.first?.id)),
                        by: .operatorGesture)
                    return .paneShow(hidden)
                }
            ),
        ]
        let cases: [(BenchActor, Bool, Bool)] = [
            (.operatorGesture, false, true),
            (.agent(), false, false),
            (.agent(), true, true),
        ]
        for (name, verb) in verbs {
            for (actor, asked, takes) in cases {
                let model = mounted()
                let prepared = try verb(model)
                let before = try XCTUnwrap(model.bench?.focusedPane?.id)

                let pane = try XCTUnwrap(
                    model.send(prepared, by: actor, asked: asked), "\(name) did not act")

                XCTAssertNotNil(
                    model.bench?.pane(pane), "\(name): reported a pane not on the bench")
                XCTAssertEqual(
                    model.bench?.focusedPane?.id, takes ? pane : before,
                    "\(name) by \(actor), asked: \(asked)")
            }
        }
    }

    /// The one kind that never takes the keyboard (#350): the browser is something to glance at
    /// while work goes on, so even the operator's ⌘⇧B leaves it where it was.
    func testTheBrowserIsOfferedWhoeverAsks() throws {
        let model = mounted()
        let typing = try XCTUnwrap(model.bench?.focusedPane?.id)

        let browser = try XCTUnwrap(
            model.send(.paneOpen(surface: .browser), by: .operatorGesture))

        XCTAssertEqual(model.bench?.pane(browser)?.content, .browser)
        XCTAssertEqual(model.bench?.focusedPane?.id, typing)
    }

    /// A verb that names a workspace acts on that workspace or not at all. An agent's canvas
    /// for a workspace with no bench to hold it is dropped rather than landing on the one open.
    func testAVerbNamingAnotherWorkspaceDoesNotTouchTheOpenBench() throws {
        let model = mounted()
        let before = try XCTUnwrap(model.bench)

        XCTAssertNil(
            model.send(
                .paneOpen(workspace: "/tmp/elsewhere", surface: .canvas(path: "/tmp/b.md")),
                by: .agent()))
        XCTAssertNil(
            model.send(
                .paneOpen(workspace: "/tmp/elsewhere", surface: .terminal(agent: nil)),
                by: .operatorGesture))
        XCTAssertNil(
            model.send(.paneSplit(workspace: "/tmp/elsewhere", direction: .right), by: .agent()))
        XCTAssertEqual(model.bench, before)

        XCTAssertNotNil(
            model.send(
                .paneOpen(workspace: workspace.value, surface: .canvas(path: "/tmp/b.md")),
                by: .agent()),
            "…while naming the open one is the same as naming none")
    }

    /// The verbs that rearrange rather than create: each reaches the bench.
    func testRearrangingVerbsReachTheBench() throws {
        let model = mounted()
        let first = try XCTUnwrap(model.bench?.focusedPane?.id)
        let second = try XCTUnwrap(model.send(.paneSplit(direction: .right), by: .operatorGesture))
        let columns = try XCTUnwrap(model.bench?.columns.map(\.id))

        model.send(.focusStep(direction: .left), by: .operatorGesture)
        XCTAssertEqual(model.bench?.focusedPane?.id, first, "focus/step")

        let slot = try XCTUnwrap(model.bench?.slot(for: second)?.id)
        model.send(.focusSlot(slot), by: .operatorGesture)
        XCTAssertEqual(model.bench?.focusedPane?.id, second, "focus/slot")

        model.send(
            .layoutResize(.columns(member: columns[0], against: columns[1]), fraction: 0.7),
            by: .operatorGesture)
        XCTAssertEqual(
            model.bench?.columns.first?.width ?? 0, 0.7, accuracy: 0.001, "layout/resize")

        model.send(.paneName(second, .chosen("build")), by: .agent())
        XCTAssertEqual(model.bench?.pane(second)?.name, .chosen("build"), "pane/name")

        model.send(.paneMove(second, .left), by: .operatorGesture)
        XCTAssertEqual(model.bench?.columns.count, 1, "pane/move")

        model.send(.paneClose(second), by: .operatorGesture)
        XCTAssertNil(model.bench?.pane(second), "pane/close")
    }

    /// Opening, closing and switching workspaces span the workspace list and the bench, so the
    /// sink hands them to whoever holds both — `RootView` in the app.
    func testWorkspaceVerbsGoToWhoeverHoldsTheWorkspaceList() {
        let model = mounted()
        var handed: [BenchVerb] = []
        model.workspaceVerbs = { handed.append($0) }

        model.send(.workspaceOpen(path: "/tmp/a"), by: .operatorGesture)
        model.send(.workspaceActivate(path: "/tmp/a"), by: .operatorGesture)
        model.send(.workspaceClose(path: "/tmp/a"), by: .operatorGesture)

        XCTAssertEqual(
            handed,
            [
                .workspaceOpen(path: "/tmp/a"), .workspaceActivate(path: "/tmp/a"),
                .workspaceClose(path: "/tmp/a"),
            ])
    }
}
