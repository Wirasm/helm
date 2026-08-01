import XCTest

@testable import Helm

final class WorkspaceContextTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "helm-workspace-context-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSaveRestoreRoundTrip() {
        let id = UUID()
        let context = WorkspaceContext(
            terminalSessionIDs: [id], selectedTerminalID: id, openArtifactPath: "/tmp/a.md",
            branch: "main", branchResolved: true)
        WorkspaceContextStore.save(["/workspace": context], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults)["/workspace"]
        XCTAssertEqual(restored, context, "contexts must round-trip through helm defaults")
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
