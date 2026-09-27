import HelmWire
import XCTest

@testable import Helm

/// The Worktrees drawer's pure parts (#382): which pane works in which worktree, what a key
/// does, and how git's upstream words are read.
final class WorktreesDrawerTests: XCTestCase {
    // MARK: - Occupants

    /// A pane counts for the deepest worktree it is inside, never the main checkout around it,
    /// and never a sibling that merely shares a prefix.
    func testAPaneCountsForTheDeepestWorktreeItIsIn() {
        let paths = ["/p/helm", "/p/helm/.worktrees/drawer", "/p/helm-docs"]
        let occupants: [WorktreeOccupants.Occupant] = [
            .init(cwd: "/p/helm/.worktrees/drawer/Sources", label: "claude · drawer"),
            .init(cwd: "/p/helm", label: "shell"),
            .init(cwd: "/p/helm-docsx", label: "stranger"),
            .init(cwd: "/elsewhere", label: "nobody's"),
        ]

        XCTAssertEqual(
            WorktreeOccupants.assign(occupants, to: paths),
            ["/p/helm/.worktrees/drawer": ["claude · drawer"], "/p/helm": ["shell"]])
    }

    /// Read from benchd's document: a terminal's shell directory, or its agent's where benchd
    /// has not read one yet, from every workspace and every drawer.
    func testOccupantsAreEveryTerminalInTheDocumentThatSaysWhereItIs() {
        let agent = BenchDocument.Agent(command: "claude", session: "s", cwd: "/p/agent")
        let bench = ToyBench.bench([
            .init(id: UUID(), surface: .terminal(agent: nil, session: "a", cwd: "/p/shell")),
            .init(
                id: UUID(), surface: .terminal(agent: agent, session: nil),
                name: .derived("claude · helm")),
            .init(id: UUID(), surface: .terminal(agent: nil, session: "b")),
            .init(id: UUID(), surface: .browser),
        ])
        let drawerPane = BenchDocument.Pane(
            id: UUID(), surface: .terminal(agent: agent, session: "c", cwd: "/p/drawer"))
        let document = BenchDocument(
            workspaces: [.init(path: "/p", bench: bench)], active: "/p",
            drawers: [.init(name: "scratch", panes: [drawerPane], selected: drawerPane.id)])

        XCTAssertEqual(
            WorktreeOccupants.occupants(of: document),
            [
                .init(cwd: "/p/shell", label: "shell"),
                .init(cwd: "/p/agent", label: "claude · helm"),
                .init(cwd: "/p/drawer", label: "claude"),
            ])
    }

    // MARK: - Keys

    func testEachKeyActsOnlyWhereItApplies() {
        let merged = Worktree.fixture(path: "/w/merged")
        let unmerged = Worktree.fixture(path: "/w/unmerged", mergedState: .unmerged)
        let missing = Worktree.fixture(path: "/w/gone", exists: false, prunable: true)
        let main = Worktree.fixture(path: "/w", branch: "main", isMain: true)
        let repo = WorktreeRepo(
            commonDir: GitCommonDir("/w/.git"), worktrees: [main, merged, unmerged, missing])
        let nothingMerged = WorktreeRepo(
            commonDir: GitCommonDir("/v/.git"), worktrees: [main, unmerged])
        let bare = WorktreeRepo(
            commonDir: GitCommonDir("/b.git"),
            worktrees: [.fixture(path: "/b.git", isMain: true, bare: true)])

        XCTAssertEqual(WorktreesKeys.action(for: "r", on: nil, in: nil), .refresh)
        XCTAssertEqual(
            WorktreesKeys.action(for: "\r", on: merged, in: repo), .openWorkspace(merged))
        XCTAssertEqual(WorktreesKeys.action(for: "\r", on: missing, in: repo), .none)
        XCTAssertEqual(WorktreesKeys.action(for: "t", on: main, in: repo), .openTerminal(main))
        XCTAssertEqual(
            WorktreesKeys.action(for: "n", on: unmerged, in: repo),
            .create(repo: GitCommonDir("/w/.git")))
        XCTAssertEqual(
            WorktreesKeys.action(for: "n", on: bare.worktrees[0], in: bare), .none,
            "a bare repository has no checkout to add a worktree from")
        XCTAssertEqual(WorktreesKeys.action(for: "d", on: unmerged, in: repo), .delete(unmerged))
        XCTAssertEqual(WorktreesKeys.action(for: "d", on: missing, in: repo), .delete(missing))
        XCTAssertEqual(WorktreesKeys.action(for: "d", on: main, in: repo), .none)
        XCTAssertEqual(
            WorktreesKeys.action(for: "D", on: unmerged, in: repo),
            .cleanMerged(repo: GitCommonDir("/w/.git")),
            "clean-merged is the repository's, whichever row is selected")
        XCTAssertEqual(WorktreesKeys.action(for: "D", on: unmerged, in: nothingMerged), .none)
        XCTAssertEqual(WorktreesKeys.action(for: "x", on: merged, in: repo), .none)
        XCTAssertEqual(
            WorktreesKeys.hints(on: main, in: nothingMerged),
            ["↑↓ select", "r refresh", "⏎ workspace", "t terminal", "n new"])
    }

    /// The line a terminal runs to stand in a worktree survives a quote in the path.
    func testTheTerminalLineQuotesThePath() {
        XCTAssertEqual(
            WorktreesDrawer.changeDirectoryLine(to: "/p/it's here"), "cd '/p/it'\\''s here'")
    }

    // MARK: - Upstream words

    func testUpstreamTrackIsReadAsGitWritesIt() {
        XCTAssertEqual(WorktreeTracking.parse(""), .counts(ahead: 0, behind: 0))
        XCTAssertEqual(WorktreeTracking.parse("ahead 3"), .counts(ahead: 3, behind: 0))
        XCTAssertEqual(WorktreeTracking.parse("behind 2"), .counts(ahead: 0, behind: 2))
        XCTAssertEqual(WorktreeTracking.parse("ahead 1, behind 4"), .counts(ahead: 1, behind: 4))
        XCTAssertEqual(WorktreeTracking.parse("gone"), .gone)
        XCTAssertNil(WorktreeTracking.parse("diverged somehow"), "unknown words are not in step")
    }
}
