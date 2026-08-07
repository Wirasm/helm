import HelmWire
import XCTest

@testable import Helm

/// The bench's half of #205: a push records **which agent** put the canvas there, and a mark made
/// on that canvas later reaches that agent and nobody else.
///
/// `CanvasNoteRouteTests` pins the decision and `CanvasNoteCourierTests` the write. Neither can
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
    private var mailRoot: URL!
    private var registryRoot: URL!
    private var artifacts: URL!
    private var canvas: URL!

    /// Which pid each pane's pty reports as its foreground process. Filled in after the sessions
    /// exist; the courier's `foregroundPid` seam reads it, so no pty and no live agent are needed.
    private var pids: [UUID: pid_t] = [:]

    private let workspace = WorkspacePath("/tmp/helm-canvas-origin")
    private let handle = Handle(validating: "sild-611a")!
    private let otherHandle = Handle(validating: "other-9c2f")!
    private let agentPid: pid_t = 40501
    private let otherPid: pid_t = 40502

    override func setUpWithError() throws {
        let fm = FileManager.default
        mailRoot = fm.temporaryDirectory.appendingPathComponent("helm-origin-mail-\(UUID())")
        registryRoot = fm.temporaryDirectory.appendingPathComponent("helm-origin-reg-\(UUID())")
        artifacts = fm.temporaryDirectory.appendingPathComponent("helm-origin-canvas-\(UUID())")
        try Self.claim(handle, pid: agentPid, under: mailRoot, registry: registryRoot)
        try Self.claim(otherHandle, pid: otherPid, under: mailRoot, registry: registryRoot)
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        canvas = artifacts.appendingPathComponent("report.md")
        try "# Report\n\nWhy this exists\n".write(to: canvas, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: mailRoot)
        try? FileManager.default.removeItem(at: registryRoot)
        try? FileManager.default.removeItem(at: artifacts)
        pids = [:]
    }

    /// `nonisolated static` because `setUpWithError` is not on the main actor even in a
    /// `@MainActor` test case, and reaching an instance from it is a data race the compiler
    /// refuses.
    private nonisolated static func claim(
        _ handle: Handle, pid: pid_t, under root: URL, registry: URL
    ) throws {
        let box = root.appendingPathComponent(handle.value)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        try """
        {"handle":"\(handle.value)","runtime":"claude","pid":\(pid),
         "sessionId":"e6f1c2d8-0000-4000-8000-0000000\(pid)","cwd":"/work",
         "claimedAt":1785831967319}
        """
        .write(to: box.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        // And the registry row that makes it resolvable. Since #247 an owner carrying a
        // `sessionId` is matched by its SESSION, never by its recorded pid — so a mailbox with
        // no row here is an agent helm cannot place, which is the point of that change and not
        // something a fixture gets to skip.
        try FileManager.default.createDirectory(
            at: registry, withIntermediateDirectories: true)
        try """
        {"pid":\(pid),"sessionId":"e6f1c2d8-0000-4000-8000-0000000\(pid)","cwd":"/work"}
        """
        .write(
            to: registry.appendingPathComponent("\(pid).json"),
            atomically: true, encoding: .utf8)
    }

    /// A bench whose canvas notes go to `mailRoot`, and whose panes report the pids this test
    /// chose. `foregroundPid` is the seam `BenchSnapshotModel` already takes for this reason;
    /// `ancestors` is stubbed empty, which makes every pane its own login shell — the direct-hit
    /// branch of `AddressBook.owner(foregroundPid:shellPid:ancestors:)`, and the only one a test can
    /// state without a process
    /// tree to walk.
    private func mounted() -> (WorkbenchModel, TerminalManager) {
        let manager = TerminalManager()
        let model = WorkbenchModel(
            terminals: manager,
            notes: CanvasNoteCourier(
                mailboxRoot: mailRoot,
                foregroundPid: { [weak self] session in self?.pids[session.id] },
                ancestors: { _ in [] },
                registryRoot: registryRoot))
        model.activate(workspacePath: workspace)
        return (model, manager)
    }

    private func push(from terminal: UUID) async throws {
        HelmCommand.pushCanvasFile(
            CanvasPushRequest(
                artifact: canvas, workspacePath: workspace,
                origin: CanvasOrigin(terminal: terminal))
        ).post()
        try await Task.sleep(for: .milliseconds(100))
    }

    private func mark(_ comment: String, on model: CanvasModel) throws {
        let page = try CanvasScriptRuntime()
        page.select(id: "intro", text: "Why this exists")
        // The script posts on **mouseup**, never on the selection itself — a highlight the
        // operator is still dragging is not a mark.
        page.mouse("mouseup", 100, 110)
        let report = try CanvasPageSelection.decode(try XCTUnwrap(page.lastPosted)).get()
        model.pageDidReport(report)
        model.annotate(comment: comment)
    }

    private func messages(in handle: Handle) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: mailRoot.appendingPathComponent(handle.value).path)
            .filter { $0.hasSuffix(".json") && $0 != "owner.json" && !$0.hasPrefix(".") }
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
        pids[terminal.id] = agentPid

        try await push(from: terminal.id)
        try mark("this shouldn't talk to that", on: try pushedCanvas(of: model))

        XCTAssertEqual(try messages(in: handle).count, 1)
        XCTAssertEqual(try messages(in: otherHandle), [])
    }

    /// **The negative half, and the one that matters.** A route that always picks the first live
    /// mailbox passes the test above for free. Here two agents are reachable, in two panes, and
    /// only one of them pushed — *"more than one agent plausibly wants it — do not guess; the
    /// origin is the origin"* (#205).
    func testTheNoteGoesToThePusherAndNotToWhateverElseIsRunning() async throws {
        let (model, manager) = mounted()
        let pusher = try XCTUnwrap(manager.sessions(for: workspace).first)
        let bystander = try XCTUnwrap(model.newTerminal())
        pids[pusher.id] = agentPid
        pids[bystander.id] = otherPid

        try await push(from: pusher.id)
        try mark("route this to the pusher", on: try pushedCanvas(of: model))

        XCTAssertEqual(try messages(in: handle).count, 1)
        XCTAssertEqual(
            try messages(in: otherHandle), [],
            "an agent that happens to be running is not an agent that asked to hear")
    }

    /// A canvas the operator opened by hand has no origin, so there is no route — and the pane
    /// says so rather than doing nothing silently.
    func testACanvasTheOperatorOpenedHasNoOriginAndSendsNothing() throws {
        let (model, manager) = mounted()
        pids[try XCTUnwrap(manager.sessions(for: workspace).first).id] = agentPid

        let opened = try XCTUnwrap(model.open(.file(canvas)))
        let pane = try XCTUnwrap(model.bench?.pane(opened))
        try mark("nobody pushed this", on: model.canvas(for: pane))

        XCTAssertEqual(try messages(in: handle), [])
        XCTAssertEqual(
            model.canvas(for: pane).notesNotice,
            "Written to report.notes.md and copied — no agent pushed this canvas, "
                + "so paste it to one")
    }

    /// The origin agent is gone — the pane was closed, the session ended, or it never claimed a
    /// mailbox. Same fallback, a different sentence, because they are different answers to "why
    /// did nothing send?".
    func testAnOriginWhoseMailboxIsGoneFallsBackAndSaysWhich() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        pids[terminal.id] = 999_999

        try await push(from: terminal.id)
        let pane = try XCTUnwrap(model.bench?.canvasPanes.first)
        try mark("the pusher has gone", on: model.canvas(for: pane))

        XCTAssertEqual(try messages(in: handle), [])
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
        pids[first.id] = agentPid
        pids[second.id] = otherPid

        try await push(from: first.id)
        try await push(from: second.id)

        XCTAssertEqual(model.bench?.canvasPanes.count, 1, "the second push found the pane open")
        try mark("the second agent owns this now", on: try pushedCanvas(of: model))

        XCTAssertEqual(try messages(in: otherHandle).count, 1)
        XCTAssertEqual(try messages(in: handle), [])
    }

    /// Closing the canvas drops the origin with it — the next canvas to land on a recycled pane
    /// id must not inherit a route nobody asked for.
    func testClosingACanvasForgetsWhoPushedIt() async throws {
        let (model, manager) = mounted()
        let terminal = try XCTUnwrap(manager.sessions(for: workspace).first)
        pids[terminal.id] = agentPid

        try await push(from: terminal.id)
        let pane = try XCTUnwrap(model.bench?.canvasPanes.first)
        model.close(pane.id)

        let opened = try XCTUnwrap(model.open(.file(canvas)))
        let reopened = try XCTUnwrap(model.bench?.pane(opened))
        try mark("opened by hand this time", on: model.canvas(for: reopened))

        XCTAssertEqual(try messages(in: handle), [])
    }
}
