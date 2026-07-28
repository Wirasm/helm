import XCTest

@testable import Helm

/// Attributing kilds to the folder you have open.
///
/// This replaces a deleted endpoint rather than a renamed one, so it is new logic rather
/// than a port — and it is path comparison, which is where this kind of code usually goes
/// quietly wrong. Every test here is a spelling of "the same directory" that a naive string
/// compare gets wrong.
final class WorkspaceAttributionTests: XCTestCase {

    private func kild(_ name: String, cwd: String, worktree: String? = nil) -> Kild {
        Kild(id: name, name: name, cwd: cwd, worktree: worktree, agents: [])
    }

    // MARK: - Containment

    func testAKildRunningInTheWorkspaceBelongsToIt() {
        let kilds = [kild("a", cwd: "/repo")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo", from: kilds).map(\.name), ["a"])
    }

    func testAKildInASubdirectoryBelongsToIt() {
        let kilds = [kild("a", cwd: "/repo/packages/core")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo", from: kilds).map(\.name), ["a"])
    }

    func testAKildInAnotherProjectDoesNot() {
        let kilds = [kild("a", cwd: "/other")]
        XCTAssertTrue(WorkspaceAttribution.kilds(in: "/repo", from: kilds).isEmpty)
    }

    /// The bug a plain `hasPrefix` produces: `/repo-backup` starts with `/repo`, so another
    /// project's kilds would silently appear as yours. The separator is what prevents it.
    func testASiblingWithASharedPrefixIsNotInside() {
        let kilds = [kild("a", cwd: "/repo-backup")]
        XCTAssertTrue(
            WorkspaceAttribution.kilds(in: "/repo", from: kilds).isEmpty,
            "/repo-backup is not inside /repo")
    }

    func testASiblingSharingAPrefixWithDeeperPathIsAlsoExcluded() {
        let kilds = [kild("a", cwd: "/repo-backup/src")]
        XCTAssertTrue(WorkspaceAttribution.kilds(in: "/repo", from: kilds).isEmpty)
    }

    // MARK: - Path spellings

    func testATrailingSlashOnTheWorkspaceStillMatches() {
        let kilds = [kild("a", cwd: "/repo")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo/", from: kilds).map(\.name), ["a"])
    }

    func testATrailingSlashOnTheKildStillMatches() {
        let kilds = [kild("a", cwd: "/repo/")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo", from: kilds).map(\.name), ["a"])
    }

    /// A persisted workspace path may be tilde-abbreviated; the engine always reports
    /// absolute paths. Comparing the two spellings as strings never matches.
    func testTildePathsAreExpandedBeforeComparing() {
        let home = NSString(string: "~").expandingTildeInPath
        let kilds = [kild("a", cwd: "\(home)/Projects/helm")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "~/Projects/helm", from: kilds).map(\.name), ["a"])
    }

    /// macOS symlinks `/var` under `/private`. `NSOpenPanel` hands back `/private/var/…`
    /// while a shell or config says `/var/…` — one directory, two spellings.
    func testPrivateVarAndVarAreTheSameDirectory() {
        let kilds = [kild("a", cwd: "/private/var/folders/x/repo")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/var/folders/x/repo", from: kilds).map(\.name),
            ["a"])
    }

    func testPrivateTmpAndTmpAreTheSameDirectory() {
        let kilds = [kild("a", cwd: "/tmp/scratch")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/private/tmp/scratch", from: kilds).map(\.name),
            ["a"])
    }

    func testNormalisingIsIdempotent() {
        let once = WorkspaceAttribution.normalise("/var/folders/x/")
        XCTAssertEqual(WorkspaceAttribution.normalise(once), once)
    }

    func testRootIsNotStrippedToEmpty() {
        XCTAssertEqual(WorkspaceAttribution.normalise("/"), "/")
    }

    // MARK: - Worktree kilds

    /// The case that motivated the old `/api/worktrees` call: a kild's *worktree* lives
    /// under `$KILD_HOME`, nowhere near the project folder, so no path test on the worktree
    /// can attribute it. `cwd` is the project directory and is what makes this work without
    /// a second request.
    func testAWorktreeKildIsAttributedByCwdNotByWorktreeLocation() {
        let kilds = [kild("feature", cwd: "/repo", worktree: "feature")]
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo", from: kilds).map(\.name), ["feature"])
    }

    /// An orphan has no record, but it does still carry `cwd` — which is the whole reason
    /// the engine enumerates it with one. Without attribution, abandoned trees would be
    /// visible but unplaceable.
    func testAnOrphanIsStillAttributable() {
        var orphan = kild("ghost", cwd: "/repo", worktree: "ghost")
        orphan.orphan = true
        XCTAssertEqual(
            WorkspaceAttribution.kilds(in: "/repo", from: [orphan]).map(\.name), ["ghost"])
    }

    // MARK: - Archive

    func testArchivedKildsAreAttributedByTheirPersistedCwd() {
        let archived = ArchivedKild(id: "a", name: "a", agents: [], cwd: "/repo")
        XCTAssertEqual(
            WorkspaceAttribution.archived(in: "/repo", from: [archived]).map(\.name), ["a"])
    }

    /// An archive that cannot say where it ran is not evidence that it ran here. Attributing
    /// it to whichever folder happens to be open would be inventing provenance — so it is
    /// excluded rather than guessed at.
    func testAnArchiveWithNoRecordedCwdIsExcludedRatherThanGuessed() {
        let archived = ArchivedKild(id: "a", name: "old", agents: [], cwd: nil)
        XCTAssertTrue(WorkspaceAttribution.archived(in: "/repo", from: [archived]).isEmpty)
    }
}
