import XCTest

@testable import Helm

/// The archive.
///
/// 179 pre-rename records were dropped rather than accommodated — they decoded cleanly and
/// held nothing, and building a careful rendering of nothing is not worth a line of code.
/// What remains is the rule that survives that cleanup and matters permanently: absent data
/// is treated as absent, never synthesised into something that looks like a fact. `endedAt`
/// is still optional on the wire, so the ordering must stay total and stable without it.
final class ArchiveTests: XCTestCase {

    /// `worktree` defaults to `name` for brevity, but every test that cares about the
    /// worktree branch of search MUST pass a different one — otherwise `name` satisfies the
    /// query on its own and deleting the worktree lookup breaks nothing.
    private func archived(
        _ name: String, worktree: String? = nil, cwd: String? = nil,
        endedAt: Double? = nil, agents: [Agent] = [], landed: LandedSummary? = nil
    ) -> ArchivedKild {
        ArchivedKild(
            id: name, name: name, worktree: worktree ?? name, agents: agents, cwd: cwd,
            landed: landed, endedAt: endedAt)
    }

    // MARK: - Ordering with no clocks

    /// With `endedAt` absent everywhere, "newest first" has nothing to sort on. The rule
    /// must still be total and stable, or the list reshuffles between renders.
    @MainActor
    func testClocklessArchivesSortStablyByName() {
        let sorted = [archived("zulu"), archived("alpha"), archived("mike")]
            .sorted(by: Cockpit.newestFirst)
        XCTAssertEqual(sorted.map(\.name), ["alpha", "mike", "zulu"])
    }

    /// A record that knows when it ended outranks every record that does not — the few
    /// dated ones surface rather than being lost among 179 undated.
    @MainActor
    func testDatedArchivesOutrankClocklessOnes() {
        let sorted = [archived("old"), archived("dated", endedAt: 1_000), archived("also")]
            .sorted(by: Cockpit.newestFirst)
        XCTAssertEqual(sorted.first?.name, "dated")
    }

    @MainActor
    func testAmongDatedArchivesNewestComesFirst() {
        let sorted = [archived("older", endedAt: 100), archived("newer", endedAt: 900)]
            .sorted(by: Cockpit.newestFirst)
        XCTAssertEqual(sorted.map(\.name), ["newer", "older"])
    }

    // MARK: - Attribution

    /// 179 of 184 records have no `cwd`. Excluding them is deliberate: attributing a kild
    /// to whichever folder happens to be open would be inventing provenance, and the
    /// operator would have no way to tell an invented attribution from a recorded one.
    func testArchivesWithNoRecordedProjectAreExcludedNotGuessed() {
        let records = [archived("placed", cwd: "/repo"), archived("unplaced", cwd: nil)]
        let attributed = WorkspaceAttribution.archived(in: "/repo", from: records)
        XCTAssertEqual(attributed.map(\.name), ["placed"])
    }

    // MARK: - Search

    /// Search covers what the listing carries. It cannot cover message text — the archive
    /// ships no log — and it cannot cover agent handles for pre-rename records, because
    /// their `agents` array is empty.
    func testSearchMatchesTheName() {
        XCTAssertTrue(archived("sidebar-observe").matchesSearch("observe"))
        XCTAssertTrue(archived("sidebar-observe").matchesSearch("SIDEBAR"))
        XCTAssertFalse(archived("sidebar-observe").matchesSearch("nothing"))
    }

    /// The worktree must be searched INDEPENDENTLY of the name.
    ///
    /// Every fixture previously set `worktree == name`, so the name satisfied every query
    /// and deleting the worktree lookup broke no test — reachable, but a break in it was
    /// invisible. A `kild/*` branch name is often the only thing an operator remembers
    /// about an abandoned kild, so this is worth guarding properly.
    func testSearchMatchesAWorktreeThatDiffersFromTheName() {
        let record = archived("nightly-triage", worktree: "fix-1168-provider")
        XCTAssertTrue(record.matchesSearch("1168"), "found by branch name alone")
        XCTAssertFalse(record.matchesSearch("unrelated"))
    }

    func testSearchMatchesAnAgentHandleWhenOneSurvives() {
        let record = archived("k", agents: [Agent(handle: "reviewer", ownership: .owned)])
        XCTAssertTrue(record.matchesSearch("reviewer"))
    }

    // MARK: - What an archive can still say

    /// `landed` is the one substantive fact a stopped kild retains, when it was landed
    /// through the engine. Worth surfacing precisely because so little else survives.
    func testALandedArchiveRetainsWhatItMerged() {
        let record = archived("shipped", landed: LandedSummary(commits: 3, files: 7))
        XCTAssertEqual(record.landed?.commits, 3)
        XCTAssertEqual(record.landed?.files, 7)
    }
}
