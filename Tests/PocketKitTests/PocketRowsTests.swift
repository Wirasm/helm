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

    /// A chat looks for a prompt's choices only when the agent says it waits: mail to him asks
    /// for him too, but the screen behind it holds no prompt, and numbered lines in a reply there
    /// must not become buttons that type into the agent.
    func testOnlyAWaitingAgentHasAPromptToAnswer() {
        let mail = BenchOperatorMail(unread: 1, since: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(row("x", running("waiting", "permission prompt")).waitsAtPrompt)
        XCTAssertFalse(row("x", running("idle"), mail: mail).waitsAtPrompt)
        XCTAssertFalse(row("x", running("busy")).waitsAtPrompt)
        XCTAssertFalse(row("x", .finished(atMs: 1)).waitsAtPrompt)
    }

    /// What a row wants from the operator, from what benchd says of it (#623): ● it waits on him
    /// (a prompt, a block, or mail to him unread), ✓ its turn ended and he has not looked, ○ it
    /// works; then, dimmed, ✓ a turn he has seen and ✓ a session that ended. Every activity word
    /// benchd sends (`bench_wire::Activity`) lands somewhere on purpose.
    func testEveryStateHasItsAttention() {
        let done = BenchDone(since: Date(timeIntervalSince1970: 1), to: "operator", seen: false)
        let seen = BenchDone(since: Date(timeIntervalSince1970: 1), to: "operator", seen: true)
        // A worker's turn is its orchestrator's to read, not the operator's.
        let toAgent = BenchDone(since: Date(timeIntervalSince1970: 1), to: "lead", seen: false)
        let mail = BenchOperatorMail(unread: 1, since: Date(timeIntervalSince1970: 1))
        let cases: [(BenchSessionRow, Attention)] = [
            (row("x", running("waiting", "permission prompt")), .asking),
            (row("x", running("waiting")), .asking),
            (row("x", running("blocked", "needs_approval")), .asking),
            (row("x", running("idle"), mail: mail), .asking),
            (row("x", running("idle"), done: done), .finished),
            (row("x", running("idle"), done: seen), .seen),
            (row("x", running("idle"), done: toAgent), .seen),
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

    /// A session two workspaces list (one inside the other) belongs to the most specific one its
    /// cwd is in (operator, 2026-10-03), so home and agents list it once. One whose cwd is in
    /// neither, a worktree elsewhere, stays with the first workspace that listed it.
    func testASessionBelongsToTheMostSpecificWorkspaceItRunsIn() {
        let inner = row("inner", running("busy"), cwd: "/w/helm/.worktrees/x/sub")
        let outer = row("outer", running("busy"), cwd: "/w/helm/Sources")
        let away = row("away", running("busy"), cwd: "/elsewhere/helm-x")
        let sibling = row("sibling", running("busy"), cwd: "/w/helm2")
        let owners = PocketHome.owners(
            [
                "/w/helm": [inner, outer, away],
                "/w/helm/.worktrees/x": [inner, away],
                "/w/helm2": [sibling],
            ],
            // The outer workspace first, so "the first that listed it" is not the answer.
            workspaces: ["/w/helm", "/w/helm/.worktrees/x", "/w/helm2"])
        XCTAssertEqual(owners["/w/helm/.worktrees/x"]?.map(\.id), ["inner"])
        XCTAssertEqual(owners["/w/helm"]?.map(\.id), ["outer", "away"])
        XCTAssertEqual(owners["/w/helm2"]?.map(\.id), ["sibling"])
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
