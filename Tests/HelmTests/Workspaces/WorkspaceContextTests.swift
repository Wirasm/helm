import XCTest

@testable import Helm

final class WorkspaceContextTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try isolatedDefaults("workspace-context")
    }

    func testSaveRestoreRoundTrip() {
        let id = UUID()
        // `Equatable` is synthesized off the stored properties, so `workbench` is part of
        // equality now: the fixture carries one rather than the assertion being loosened.
        let context = WorkspaceContext(
            terminalSessionIDs: [id], selectedTerminalID: id, openArtifactPath: "/tmp/a.md",
            branch: "main", branchResolved: true, workbench: Workbench(terminal: id))
        WorkspaceContextStore.save(["/workspace": context], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults)["/workspace"]
        XCTAssertEqual(restored, context, "contexts must round-trip through helm defaults")
    }

    // MARK: - Tolerant decode

    /// Every field is read with `try?` and falls back to its default, so a single bad or
    /// missing value costs that field and nothing else. Before this, one corrupt value
    /// threw for the whole entry — and, because the store decodes the dictionary
    /// atomically, for every OTHER workspace's context too.
    func testAFieldOfTheWrongTypeCostsThatFieldAlone() {
        let id = UUID()
        let blob = """
            {"/workspace":{"terminalSessionIDs":["\(id.uuidString)"],
                           "branchResolved":"yes please","branch":17,
                           "openArtifactPath":"/tmp/a.md"}}
            """
        defaults.set(blob, forKey: WorkspaceContextStore.key)

        let restored = WorkspaceContextStore.load(from: defaults)["/workspace"]

        XCTAssertEqual(restored?.terminalSessionIDs, [id], "the good fields still decode")
        XCTAssertEqual(restored?.openArtifactPath, "/tmp/a.md")
        XCTAssertFalse(restored?.branchResolved ?? true, "a bad bool falls back to its default")
        XCTAssertNil(restored?.branch, "a bad optional falls back to nil")
    }

    func testAMissingKeyIsNotAnError() {
        defaults.set(#"{"/workspace":{}}"#, forKey: WorkspaceContextStore.key)

        let restored = WorkspaceContextStore.load(from: defaults)["/workspace"]

        XCTAssertEqual(
            restored, WorkspaceContext(),
            "a blob written by an older build decodes to the defaults, not to nothing")
    }

    func testContextsAreIsolatedByWorkspacePath() {
        WorkspaceContextStore.save(
            [
                "/one": WorkspaceContext(openArtifactPath: "/one.md"),
                "/two": WorkspaceContext(openArtifactPath: "/two.md"),
            ], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults)
        XCTAssertEqual(
            restored["/one"]?.openArtifactPath, "/one.md",
            "one workspace must retain its own context")
        XCTAssertEqual(
            restored["/two"]?.openArtifactPath, "/two.md",
            "a second workspace must not overwrite the first")
    }

    /// Replaces `testDanglingSessionIDsAreDroppedOnLoad`, whose subject was removed
    /// rather than renamed. It asserted that "relaunch cannot restore sessions that
    /// no longer exist" — true of the *old* process's ptys, but it made the loader
    /// filter ids against the ids live in this process, which at launch is none. The
    /// result was that persisted terminals were always discarded before anything
    /// could restore them. The ids are now the record a relaunch rebuilds from.
    func testSessionIDsSurviveLoadSoTheyCanBeRestored() {
        let first = UUID()
        let second = UUID()
        WorkspaceContextStore.save(
            [
                "/workspace": WorkspaceContext(
                    terminalSessionIDs: [first, second], selectedTerminalID: second)
            ], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults)["/workspace"]
        XCTAssertEqual(
            restored?.terminalSessionIDs, [first, second],
            "a relaunch must still know how many terminals the workspace had, and in what order")
        XCTAssertEqual(
            restored?.selectedTerminalID, second,
            "the selected tab must survive a relaunch, not just the tab row")
    }

    func testUnvisitedWorkspaceHasDefaultsAndCorruptBlobIsEmpty() {
        XCTAssertEqual(
            WorkspaceContext(), WorkspaceContext(),
            "an unvisited workspace starts with empty UI state")
        defaults.set("not json", forKey: WorkspaceContextStore.key)
        XCTAssertTrue(
            WorkspaceContextStore.load(from: defaults).isEmpty,
            "corrupt persistence must fail closed")
    }
}
