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
        at ms: UInt64 = 0
    ) -> BenchSessionRow {
        BenchSessionRow(
            harness: "claude", id: id, cwd: cwd, state: state, open: open, updatedAtMs: ms)
    }

    private func running(_ activity: String, _ detail: String? = nil) -> BenchSessionRow.State {
        .running(activity: activity, detail: detail)
    }

    /// ● when the agent waits on him, ✓ when its turn is over, ○ while it works. Every activity
    /// word benchd sends (`bench_wire::Activity`) lands somewhere on purpose.
    func testEveryStateHasItsGlyph() {
        let cases: [(BenchSessionRow.State, Attention)] = [
            (running("waiting", "permission prompt"), .asking),
            (running("waiting"), .asking),
            (running("blocked", "needs_approval"), .asking),
            (running("idle"), .finished),
            (.finished(atMs: 1), .finished),
            (running("busy"), .working),
            (running("shell"), .working),
            (running("waiting_on_tasks", "2 tasks"), .working),
            (running("unknown"), .working),
        ]
        for (state, attention) in cases {
            XCTAssertEqual(Attention(row("x", state)), attention, "\(state)")
        }
        XCTAssertEqual([Attention.asking, .finished, .working].map(\.glyph), ["●", "✓", "○"])
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
    /// Pocket can talk to in benchd's order. A workspace with none still shows, empty.
    func testHomeGroupsTalkableSessionsUnderTheirWorkspace() {
        let sessions: [String: [BenchSessionRow]] = [
            "/w/helm": [
                row("asking", running("waiting", "permission prompt")),
                row("ended", .finished(atMs: 1), open: .resume(argv: ["claude"], cwd: "/w/helm")),
                row("job", running("busy"), open: .claudeAttach(job: "j")),
                row("busy", running("busy")),
            ],
            "/w/prp": [row("lead", running("idle"))],
        ]
        let groups = PocketHome.groups(
            workspaces: ["/w/prp", "/w/helm", "/w/kild"], sessions: sessions)
        XCTAssertEqual(groups.map(\.name), ["prp", "helm", "kild"])
        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["lead"], ["asking", "busy"], []])
    }

    /// Agents: every session on every workspace once, running before finished, newest first,
    /// as benchd orders one workspace's.
    func testAgentsListsEverySessionOnceRunningFirstNewestFirst() {
        let shared = row("shared", running("busy"), at: 50)
        let sessions: [String: [BenchSessionRow]] = [
            "/w/helm": [
                row("old", running("idle"), at: 10), shared, row("done", .finished(atMs: 90)),
            ],
            "/w/helm/.worktrees/x": [shared, row("new", running("busy"), at: 70)],
        ]
        XCTAssertEqual(
            PocketHome.agents(sessions: sessions).map(\.id), ["new", "shared", "old", "done"])
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
