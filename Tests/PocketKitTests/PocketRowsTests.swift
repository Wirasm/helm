import Foundation
import HelmWire
import XCTest

@testable import PocketKit

/// What Pocket shows for benchd's session rows: the glyph, which rows it can talk to, and how the
/// home screen groups them.
final class PocketRowsTests: XCTestCase {
    private func row(
        _ id: String, _ state: BenchSessionRow.State,
        open: BenchSessionRow.Open = .benchAttach(session: "s"), cwd: String = "/w/helm",
        at ms: UInt64 = 0, done: BenchDone? = nil, mail: BenchOperatorMail? = nil,
        spawner: BenchSpawner? = nil
    ) -> BenchSessionRow {
        BenchSessionRow(
            harness: "claude", id: id, cwd: cwd, state: state, open: open, updatedAtMs: ms,
            done: done, operatorMail: mail, spawner: spawner)
    }

    private func running(_ activity: String, _ detail: String? = nil) -> BenchSessionRow.State {
        .running(activity: activity, detail: detail)
    }

    /// What a row wants from the operator, from what benchd says of it (#623): ● it waits on him
    /// (a prompt, a block, or mail to him unread), ✓ its turn ended and he has not looked, ○ it
    /// works; then, dimmed, ✓ a turn he has seen and ✓ a session that ended. Every activity word
    /// benchd sends (`bench_wire::Activity`) lands somewhere on purpose.
    func testEveryStateHasItsAttention() {
        let done = BenchDone(since: Date(timeIntervalSince1970: 1), to: "operator", seen: false)
        let seen = BenchDone(since: Date(timeIntervalSince1970: 1), to: "operator", seen: true)
        let mail = BenchOperatorMail(unread: 1, since: Date(timeIntervalSince1970: 1))
        let cases: [(BenchSessionRow, Attention)] = [
            (row("x", running("waiting", "permission prompt")), .asking),
            (row("x", running("waiting")), .asking),
            (row("x", running("blocked", "needs_approval")), .asking),
            (row("x", running("idle"), mail: mail), .asking),
            (row("x", running("idle"), done: done), .finished),
            (row("x", running("idle"), done: seen), .seen),
            (row("x", running("idle")), .seen),
            (row("x", .finished(atMs: 1)), .ended),
            (row("x", running("busy")), .working),
            (row("x", running("shell")), .working),
            (row("x", running("waiting_on_tasks", "2 tasks")), .working),
            (row("x", running("unknown")), .working),
        ]
        for (row, attention) in cases {
            XCTAssertEqual(
                Attention(row), attention, "\(row.state) \(String(describing: row.done))")
        }
        XCTAssertEqual(
            [Attention.asking, .finished, .working, .seen, .ended].map(\.glyph),
            ["●", "✓", "○", "✓", "✓"])
    }

    /// A row Pocket can open is one whose session runs on the bench: benchd takes the session id,
    /// or the pane showing it. A background job, a finished session and a subagent's transcript
    /// have no screen.
    func testOnlyARowOnTheBenchHasAScreen() {
        let pane = UUID(uuidString: "0E8E8CC6-159B-45D8-BC02-485120975998")!
        XCTAssertEqual(row("a", running("busy"), open: .benchAttach(session: "s7")).screen, "s7")
        XCTAssertEqual(
            row("b", running("busy"), open: .focusPane(pane)).screen,
            "0e8e8cc6-159b-45d8-bc02-485120975998")
        XCTAssertNil(row("c", running("busy"), open: .claudeAttach(job: "j")).screen)
        XCTAssertNil(
            row("d", .finished(atMs: 1), open: .resume(argv: ["claude"], cwd: "/w")).screen)
        XCTAssertNil(row("e", running("busy"), open: .transcript(path: "/t", parent: "a")).screen)
    }

    /// Home: each workspace in the document's order, named by its folder, holding the sessions
    /// Pocket can talk to: the operator's orchestrators first, then the rest, each in benchd's
    /// order. A workspace with none still shows, empty.
    func testHomePinsTheOperatorsOrchestratorsInEachWorkspace() {
        let sessions: [String: [BenchSessionRow]] = [
            "/w/helm": [
                row(
                    "asking", running("waiting", "permission prompt"), spawner: .agent(handle: "o")),
                row("ended", .finished(atMs: 1), open: .resume(argv: ["claude"], cwd: "/w/helm")),
                row("job", running("busy"), open: .claudeAttach(job: "j")),
                row("busy", running("busy")),
                row("lead", running("busy"), spawner: .operator),
            ],
            "/w/prp": [row("prp-lead", running("idle"), spawner: .operator)],
        ]
        let groups = PocketHome.groups(
            workspaces: ["/w/prp", "/w/helm", "/w/kild"], sessions: sessions)
        XCTAssertEqual(groups.map(\.name), ["prp", "helm", "kild"])
        XCTAssertEqual(
            groups.map { $0.rows.map(\.id) }, [["prp-lead"], ["lead", "asking", "busy"], []])
        XCTAssertEqual(groups[1].rows.map(\.isOrchestrator), [true, false, false])
    }

    /// Agents: every session on every workspace once, by what it wants from the operator (asking,
    /// finished and not seen, working, seen, ended), newest first within each.
    func testAgentsListsEverySessionOnceByAttention() {
        let done = BenchDone(since: Date(timeIntervalSince1970: 1), to: "operator", seen: false)
        let shared = row("shared", running("busy"), at: 50)
        let sessions: [String: [BenchSessionRow]] = [
            "/w/helm": [
                row("idle", running("idle"), at: 95), shared, row("ended", .finished(atMs: 99)),
                row("unseen", running("idle"), at: 10, done: done),
            ],
            "/w/helm/.worktrees/x": [
                shared, row("new", running("busy"), at: 70), row("ask", running("waiting"), at: 1),
            ],
        ]
        XCTAssertEqual(
            PocketHome.agents(sessions: sessions).map(\.id),
            ["ask", "unseen", "new", "shared", "idle", "ended"])
    }

    /// A session is called by its mailbox handle, the name it is mailed by, before anything else.
    func testASessionIsCalledByItsHandleFirst() {
        var r = row("0b9e3f2a-1c4d", running("busy"))
        XCTAssertEqual(r.title, "0b9e3f2a")
        r.branch = "feat/pocket"
        XCTAssertEqual(r.title, "feat/pocket")
        r.name = "pocket"
        XCTAssertEqual(r.title, "pocket")
        r.handle = "daemon-7915"
        XCTAssertEqual(r.title, "daemon-7915")
    }

    /// The keys row sends each key's own bytes, as keys: Enter is a carriage return, ^C is ETX,
    /// arrows are the cursor sequences the spike saw arrive.
    func testEachKeySendsItsBytesAsKeys() {
        let bytes = Dictionary(
            uniqueKeysWithValues: PocketKey.allCases.map { ($0.label, $0.bytes) })
        XCTAssertEqual(
            bytes,
            [
                "⏎": "\r", "esc": "\u{1b}", "^c": "\u{3}", "1": "1", "2": "2", "3": "3",
                "⇥": "\t", "↑": "\u{1b}[A", "↓": "\u{1b}[B", "←": "\u{1b}[D", "→": "\u{1b}[C",
            ])
        XCTAssertEqual(PocketKey.escape.input, .keys("\u{1b}"))
    }
}
