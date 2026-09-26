import HelmWire
import XCTest

@testable import Helm

/// The bench's half of #205: a push records **which agent** put the canvas there, and a mark made
/// on that canvas later reaches that agent and nobody else.
///
/// `CanvasNoteRouteTests` pins the decision and `CanvasNoteCourierTests` the send. Neither can
/// see the thing that was actually missing — that the identity survives the hop from
/// `TerminalSession` to a pane on a bench — because that hop is `WorkbenchModel`'s, and nothing
/// but a real push through the real command reaches it.
///
/// **The mark is driven through the shipped script here too**, rather than through a dictionary
/// written by hand. #216 is what a hand-written body buys: a suite that drives one side, a suite
/// that drives the other, and a gate between them that dropped every geometry mark for months
/// with both suites green.
@MainActor
final class WorkbenchCanvasOriginTests: XCTestCase {
    private var artifacts: URL!
    private var canvas: URL!

    /// benchd, as this test answers for it: which agent reported from each pane, and every send
    /// that reached it. A class so the `@Sendable` mailbox closures can share it with the test.
    private final class Bench: @unchecked Sendable {
        var agents: [UUID: Handle] = [:]
        var sent: [Handle] = []
    }
    private var bench = Bench()

    /// What `annotate` put on the clipboard, into this suite's own list rather than the operator's
    /// pasteboard — `mark(_:on:)` takes the sink over, and `CanvasModel.copyToClipboard`'s header
    /// has why that is not pedantry.
    private var copied: [String] = []

    private let workspace = WorkspacePath("/tmp/helm-canvas-origin")
    private let handle = Handle(validating: "sild-611a")!
    private let otherHandle = Handle(validating: "other-9c2f")!

    override func setUpWithError() throws {
        let fm = FileManager.default
        artifacts = fm.temporaryDirectory.appendingPathComponent("helm-origin-canvas-\(UUID())")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        canvas = artifacts.appendingPathComponent("report.md")
        try "# Report\n\nWhy this exists\n".write(to: canvas, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: artifacts)
    }

    /// A bench whose canvas notes go to this test's benchd. `who` answers for a pane only when
    /// the test says an agent reported from it — the one fact the route now asks benchd.
    private func mounted() -> (WorkbenchModel, TerminalManager) {
        let manager = TerminalManager()
        let bench = self.bench
        let model = WorkbenchModel(
            terminals: manager,
            notes: CanvasNoteCourier(
                mail: BenchMailbox(
                    who: { pane in
                        bench.agents[pane].map {
                            BenchMailWho(
                                handle: $0, harness: "claude", session: "s-\($0.value)", pid: 1)
                        }
                    },
                    send: { to, _, _, _ in bench.sent.append(to) })))
        model.activate(workspacePath: workspace)
        return (model, manager)
    }

    /// `push.sh`'s sequence, arriving at the session that printed it — the route an agent's push
    /// takes, from the terminal's own callback onto the bench.
    private func push(from terminal: TerminalSession) {
        terminal.terminalDidRequestDesktopNotification(title: CanvasPush.marker, body: canvas.path)
    }

    private func mark(_ comment: String, on model: CanvasModel) throws {
        // **Here rather than in `mounted()`, because these models come from the production path.**
        // `WorkbenchModel.canvas(for:)` makes them and rightly leaves `copyToClipboard` at its
        // default, so the sink has to be taken over at the one point every caller passes through —
        // this is that point. Without it a fallback route reaches `Pasteboard.copy` for real and
        // this suite clears the clipboard of whoever is running the gate, which is exactly what
        // `CanvasModel.copyToClipboard`'s header says the seam exists to stop.
        model.copyToClipboard = { [weak self] text in self?.copied.append(text) }

        let page = try CanvasScriptRuntime()
        // Stated rather than left to the default (#302): a highlight is a mark only with
        // `.text` held, and the default `.read` posts nothing at all.
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")
        // The script posts on **mouseup**, never on the selection itself — a highlight the
        // operator is still dragging is not a mark.
        page.mouse("mouseup", 100, 110)
        let report = try CanvasPageSelection.decode(try XCTUnwrap(page.lastPosted)).get()
        model.pageDidReport(report)
        model.annotate(comment: comment)
    }

    private func messages(in handle: Handle) -> [Handle] {
        bench.sent.filter { $0 == handle }
    }

    private func pushedCanvas(of model: WorkbenchModel) throws -> CanvasModel {
        let pane = try XCTUnwrap(
            model.bench?.canvasPanes.first, "the push did not put a canvas on the bench")
        return model.canvas(for: pane)
    }

    // MARK: -

    /// #205's first acceptance: no pane switch, no paste.
    func testAMarkOnAPushedCanvasReachesTheAgentThatPushedIt() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        bench.agents[terminal.id] = handle

        push(from: terminal)
        try mark("this shouldn't talk to that", on: try pushedCanvas(of: model))

        XCTAssertEqual(messages(in: handle).count, 1)
        XCTAssertEqual(messages(in: otherHandle), [])
    }

    /// #349: the canvas is pushed while its workspace is **parked**, and the mark is made after the
    /// operator switches in. The origin has to survive both hops, the parked bench and the mount,
    /// or the note falls back to the clipboard and tells the operator nobody pushed it.
    func testAMarkOnACanvasPushedFromAParkedWorkspaceReachesThePusherAfterSwitchingIn()
        async throws
    {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        bench.agents[terminal.id] = handle
        let workspaces = WorkspaceModel(defaults: try isolatedDefaults("origin-parked"))
        model.parked = workspaces

        // Park it the way `RootView.switchWorkspace` does.
        workspaces.open(Workspace(path: workspace.value))
        workspaces.saveContext(terminalManager: manager, workbench: model)
        let elsewhere = WorkspacePath("/tmp/helm-canvas-origin-elsewhere")
        workspaces.open(Workspace(path: elsewhere.value))
        model.activate(workspacePath: elsewhere)

        push(from: terminal)

        workspaces.saveContext(terminalManager: manager, workbench: model)
        workspaces.open(Workspace(path: workspace.value))
        model.activate(
            workspacePath: workspace,
            restoring: workspaces.contexts[workspace.value]?.workbench)
        try mark("pushed while parked", on: try pushedCanvas(of: model))

        XCTAssertEqual(messages(in: handle).count, 1)
        XCTAssertEqual(copied, [], "a routed mark is mailed, not left on the clipboard")
    }

    /// **The negative half, and the one that matters.** A route that always picks the first live
    /// mailbox passes the test above for free. Here two agents are reachable, in two panes, and
    /// only one of them pushed — *"more than one agent plausibly wants it — do not guess; the
    /// origin is the origin"* (#205).
    func testTheNoteGoesToThePusherAndNotToWhateverElseIsRunning() async throws {
        let (model, manager) = mounted()
        let pusher = try XCTUnwrap(manager.sessions(for: workspace).first)
        let bystander = try XCTUnwrap(model.newTerminal())
        bench.agents[pusher.id] = handle
        bench.agents[bystander.id] = otherHandle

        push(from: pusher)
        try mark("route this to the pusher", on: try pushedCanvas(of: model))

        XCTAssertEqual(messages(in: handle).count, 1)
        XCTAssertEqual(
            messages(in: otherHandle), [],
            "an agent that happens to be running is not an agent that asked to hear")
    }

    /// A canvas the operator opened by hand has no origin, so there is no route — and the pane
    /// says so rather than doing nothing silently.
    func testACanvasTheOperatorOpenedHasNoOriginAndSendsNothing() throws {
        let (model, manager) = mounted()
        bench.agents[try XCTUnwrap(manager.sessions(for: workspace).first).id] = handle

        let opened = try XCTUnwrap(model.open(.file(canvas)))
        let pane = try XCTUnwrap(model.bench?.pane(opened))
        try mark("nobody pushed this", on: model.canvas(for: pane))

        XCTAssertEqual(messages(in: handle), [])
        XCTAssertEqual(
            model.canvas(for: pane).notesNotice,
            "Written to report.notes.md and copied — no agent pushed this canvas, "
                + "so paste it to one")
        // **The control for #303, on the production wiring rather than on the policy.** `sent` is
        // the case that stopped copying; an unrouted note must still land on the clipboard, because
        // here the clipboard is the only way it reaches anybody — and `WorkbenchModel.canvas(for:)`
        // is the real path that has to keep doing it.
        XCTAssertEqual(copied.count, 1, "with nobody to send to, the clipboard is the return path")
        XCTAssertTrue(try XCTUnwrap(copied.first).contains("nobody pushed this"))
    }

    /// The origin agent is gone — the pane was closed, the session ended, or it never reported
    /// to benchd. Same fallback, a different sentence, because they are different answers to "why
    /// did nothing send?".
    func testAnOriginWhoseMailboxIsGoneFallsBackAndSaysWhich() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        // No agent reports from the pane any more: benchd's `who` has nothing to say for it.

        push(from: terminal)
        let pane = try XCTUnwrap(model.bench?.canvasPanes.first)
        try mark("the pusher has gone", on: model.canvas(for: pane))

        XCTAssertEqual(messages(in: handle), [])
        XCTAssertEqual(
            model.canvas(for: pane).notesNotice,
            "Written to report.notes.md and copied — the agent that pushed this canvas is gone, "
                + "so paste it to another")
    }

    /// **Re-pushing an artifact that is already open is the common case**, not an edge one — an
    /// agent re-offering the file it just rewrote gets `.existing` back from `offer`, which
    /// returns before the commit. The origin has to be recorded on that path as well, or a canvas
    /// keeps routing to whoever pushed it first however many times it has been handed on since.
    func testRePushingAnOpenCanvasRoutesToTheNewestPusher() async throws {
        let (model, manager) = mounted()
        let first = try XCTUnwrap(manager.sessions(for: workspace).first)
        let second = try XCTUnwrap(model.newTerminal())
        bench.agents[first.id] = handle
        bench.agents[second.id] = otherHandle

        push(from: first)
        push(from: second)

        XCTAssertEqual(model.bench?.canvasPanes.count, 1, "the second push found the pane open")
        try mark("the second agent owns this now", on: try pushedCanvas(of: model))

        XCTAssertEqual(messages(in: otherHandle).count, 1)
        XCTAssertEqual(messages(in: handle), [])
    }

    /// Closing the canvas drops the origin with it — the next canvas to land on a recycled pane
    /// id must not inherit a route nobody asked for.
    func testClosingACanvasForgetsWhoPushedIt() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        bench.agents[terminal.id] = handle

        push(from: terminal)
        let pane = try XCTUnwrap(model.bench?.canvasPanes.first)
        model.close(pane.id)

        let opened = try XCTUnwrap(model.open(.file(canvas)))
        let reopened = try XCTUnwrap(model.bench?.pane(opened))
        try mark("opened by hand this time", on: model.canvas(for: reopened))

        XCTAssertEqual(messages(in: handle), [])
    }
}
