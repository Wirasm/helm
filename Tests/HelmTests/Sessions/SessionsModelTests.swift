import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The sessions drawer's list (#384): it shows what benchd answers, and each row's action is
/// carried out as benchd decided it — a verb as the operator, or a line in a new terminal.
@MainActor
final class SessionsModelTests: XCTestCase {
    /// What the model asked of the bench, in order.
    private final class Bench {
        var verbs: [BenchVerb] = []
        var lines: [String] = []
        var hidden = 0
        var dismissed: [String] = []
        var workspace: WorkspacePath? = WorkspacePath("/Users/op/Projects/helm")
    }

    nonisolated private static let fixtureRows: BenchSessionList = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("daemon/fixtures/session-rows.json")
        let data = try! Data(contentsOf: url)
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try! JSONDecoder().decode(
            BenchSessionList.self, from: JSONSerialization.data(withJSONObject: root["list"]!))
    }()

    private func model(
        _ bench: Bench,
        list: @escaping @Sendable (String) throws -> BenchSessionList = { _ in
            fixtureRows
        }
    ) -> SessionsModel {
        SessionsModel(
            actions: SessionsActions(
                list: list,
                dismiss: { _, _ in },
                workspace: { bench.workspace },
                send: { bench.verbs.append($0) },
                hideDrawer: { bench.hidden += 1 },
                runInNewTerminal: { line in
                    bench.lines.append(line)
                    return nil
                }))
    }

    private func row(_ open: BenchSessionRow.Open, finished: Bool = false) -> BenchSessionRow {
        BenchSessionRow(
            harness: "claude", id: "s1", cwd: "/w",
            state: finished ? .finished(atMs: 0) : .running(activity: "busy", detail: nil),
            open: open, updatedAtMs: 0)
    }

    func testTheRowsAreBenchdsInBenchdsOrder() async {
        let bench = Bench()
        let model = model(bench)
        await model.refresh()
        XCTAssertEqual(model.rows, Self.fixtureRows.rows)
        XCTAssertEqual(
            model.selected, Self.fixtureRows.rows.first?.id, "the keyboard starts on top")
        XCTAssertNotNil(model.problem, "the fixture's unreadable files are said, not hidden")
    }

    func testEachOpenActionIsCarriedOutAsBenchdDecided() async {
        let bench = Bench()
        let model = model(bench)
        let pane = UUID()

        await model.open(row(.focusPane(pane)))
        await model.open(row(.transcript(path: "/t/agent-1.jsonl", parent: "p")))
        await model.open(row(.benchAttach(session: "s2")))
        await model.open(row(.claudeAttach(job: "j 1")))
        await model.open(
            row(.resume(argv: ["claude", "--resume", "abc"], cwd: "/w/it's"), finished: true))

        XCTAssertEqual(
            bench.verbs,
            [.paneShow(pane), .paneOpen(surface: .canvas(path: "/t/agent-1.jsonl"))])
        XCTAssertEqual(
            bench.lines,
            [
                "'bench' 'attach' 's2'",
                "'claude' 'attach' 'j 1'",
                "cd '/w/it'\\''s' && 'claude' '--resume' 'abc'",
            ])
        XCTAssertEqual(bench.hidden, 5, "the drawer gets out of the way of whatever it opened")
    }

    /// Only a finished session can be dismissed; a running one is still work.
    func testOnlyAFinishedSessionIsDismissed() async {
        let bench = Bench()
        let dismissed = Recorder()
        let model = SessionsModel(
            actions: SessionsActions(
                list: { _ in BenchSessionList(rows: []) },
                dismiss: { harness, id in dismissed.append("\(harness)/\(id)") },
                workspace: { bench.workspace }, send: { _ in }, hideDrawer: {},
                runInNewTerminal: { _ in nil }))

        await model.dismiss(row(.focusPane(UUID())))
        await model.dismiss(row(.resume(argv: ["claude"], cwd: "/w"), finished: true))

        XCTAssertEqual(dismissed.values, ["claude/s1"])
    }

    func testAListThatCannotBeHadIsSaidAndKeepsTheLastRows() async {
        let bench = Bench()
        let fail = Flag()
        let model = model(bench) { _ in
            if fail.value { throw SessionsActions.Refused("no daemon at /tmp/benchd.sock") }
            return Self.fixtureRows
        }
        await model.refresh()
        fail.value = true
        await model.refresh()

        XCTAssertEqual(model.rows, Self.fixtureRows.rows, "the last list stays on screen")
        XCTAssertEqual(model.problem, "Could not list sessions: no daemon at /tmp/benchd.sock")
    }

    func testNoWorkspaceListsNothing() async {
        let bench = Bench()
        bench.workspace = nil
        let model = model(bench)
        await model.refresh()
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.problem, "No workspace is open.")
    }

    /// The terminal manager is shared by every window and each window registers its own kinds
    /// on it, so a closed window's registration can outlive the window. Asking it for a
    /// sessions list then makes nothing rather than reaching a freed model.
    func testAClosedWindowsRegistrationMakesNoList() {
        let terminals = TerminalManager()
        let open = WorkbenchModel(terminals: terminals, agents: .blind)
        var closed: WorkbenchModel? = WorkbenchModel(terminals: terminals, agents: .blind)
        weak let gone = closed
        closed = nil
        XCTAssertNil(gone, "the closed window's model is released")

        let pane = Pane(id: UUID(), content: .sessions)
        let slot = SurfaceSlot(
            pane: pane, holdsKeyboard: true, isSelected: true, canClose: true, select: {},
            close: {})
        XCTAssertNil(open.surfaceView(of: pane, in: slot))
    }

    func testAStatusLineSaysWhatItIsDoingAndSince() {
        let now = Date(timeIntervalSince1970: 10_000)
        func running(_ activity: String, _ detail: String?, at seconds: UInt64) -> BenchSessionRow {
            BenchSessionRow(
                harness: "claude", id: "s", cwd: "/w",
                state: .running(activity: activity, detail: detail),
                open: .focusPane(UUID()), updatedAtMs: seconds * 1000)
        }
        XCTAssertEqual(SessionLine.status(running("busy", nil, at: 9_880), now: now), "busy · 2m")
        XCTAssertEqual(
            SessionLine.status(running("waiting", "permission prompt", at: 7_600), now: now),
            "waiting: permission prompt · 40m")
        XCTAssertEqual(
            SessionLine.status(running("waiting_on_tasks", "2 tasks", at: 9_995), now: now),
            "waiting on tasks: 2 tasks · 5s")
        let finished = BenchSessionRow(
            harness: "pi", id: "s", cwd: "/w", state: .finished(atMs: 10_000_000),
            open: .resume(argv: [], cwd: "/w"), updatedAtMs: 0)
        XCTAssertEqual(
            SessionLine.status(finished, now: Date(timeIntervalSince1970: 10_000 + 3 * 3600)),
            "finished 3h ago")
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

private final class Flag: @unchecked Sendable {
    var value = false
}
