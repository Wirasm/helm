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
        let context = WorkspaceContext(terminalSessionIDs: [id], selectedTerminalID: id, selectedRoomID: "room", roomsTab: .history, openArtifactPath: "/tmp/a.md", expandedRooms: ["room"], composerDrafts: ["room": "draft"], branch: "main")
        WorkspaceContextStore.save(["/workspace": context], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults, validSessionIDs: [id])["/workspace"]
        XCTAssertEqual(restored, context, "contexts must round-trip through helm defaults")
    }

    func testContextsAreIsolatedByWorkspacePath() {
        WorkspaceContextStore.save([
            "/one": WorkspaceContext(selectedRoomID: "one"),
            "/two": WorkspaceContext(selectedRoomID: "two")
        ], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults)
        XCTAssertEqual(restored["/one"]?.selectedRoomID, "one", "one workspace must retain its own context")
        XCTAssertEqual(restored["/two"]?.selectedRoomID, "two", "a second workspace must not overwrite the first")
    }

    func testDanglingSessionIDsAreDroppedOnLoad() {
        let stale = UUID()
        WorkspaceContextStore.save(["/workspace": WorkspaceContext(terminalSessionIDs: [stale], selectedTerminalID: stale)], to: defaults)

        let restored = WorkspaceContextStore.load(from: defaults, validSessionIDs: []) ["/workspace"]
        XCTAssertEqual(restored?.terminalSessionIDs, [], "relaunch cannot restore sessions that no longer exist")
        XCTAssertNil(restored?.selectedTerminalID, "a dangling selected session must be cleared")
    }

    func testUnvisitedWorkspaceHasDefaultsAndCorruptBlobIsEmpty() {
        XCTAssertEqual(WorkspaceContext(), WorkspaceContext(), "an unvisited workspace starts with empty UI state")
        defaults.set("not json", forKey: WorkspaceContextStore.key)
        XCTAssertTrue(WorkspaceContextStore.load(from: defaults).isEmpty, "corrupt persistence must fail closed")
    }
}
