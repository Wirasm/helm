import Foundation
import XCTest

@testable import Helm

/// The workspace filter end to end: the store loads rooms from a stubbed engine and
/// narrows them to the open folder — the one behaviour the registry ever bought, now
/// keyed by a path nobody had to register.
@MainActor
final class KildStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        suiteName = "helm-kildstore-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        stubEngine(rooms: "[]", archive: "[]", worktrees: "[]")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Filtering

    func testSelectingAWorkspaceFiltersRoomsAndDeselectingShowsAll() async {
        stubEngine(
            rooms: """
            [\(room(id: "in", git: "/p/kild/sub")),
             \(room(id: "sibling", git: "/p/kild-ui")),
             \(room(id: "elsewhere", git: "/p/other"))]
            """,
            archive: "[]",
            worktrees: "[]"
        )
        let store = makeStore()
        await store.load()
        XCTAssertEqual(store.shownRooms.map(\.id).sorted(), ["elsewhere", "in", "sibling"])

        store.select(Workspace(path: "/p/kild"))
        await store.load()
        // Sibling-prefix collision must not leak in.
        XCTAssertEqual(store.shownRooms.map(\.id), ["in"])

        store.select(nil)
        await store.load()
        XCTAssertEqual(store.shownRooms.count, 3)
    }

    /// Worktree rooms live under `$KILD_HOME`, never under the workspace, so they can
    /// only be attributed by name — which is why the worktrees call survives.
    func testWorktreeRoomsAttributeByNameFromThePathQuery() async {
        stubEngine(
            rooms: "[\(room(id: "wt", git: "/home/.config/kild/worktrees/fix", worktree: "fix"))]",
            archive: "[]",
            worktrees: #"[{"branch":"kild/fix","path":"/home/.config/kild/worktrees/fix","name":"fix"}]"#
        )
        let store = makeStore()
        store.select(Workspace(path: "/p/kild"))
        await store.load()

        XCTAssertEqual(store.workspaceWorktreeNames, ["fix"])
        XCTAssertEqual(store.shownRooms.map(\.id), ["wt"])
        // The engine reference is the path, never a registered name.
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "path=/p/kild")
    }

    /// A folder that is no git repo 400s on /api/worktrees. That is legitimate: it
    /// only disables worktree matching, and must never surface as an engine error.
    func testNonRepoWorkspaceYieldsNoWorktreeNamesAndNoError() async {
        stubEngine(rooms: "[\(room(id: "r", git: "/p/notes"))]", archive: "[]", worktrees: nil)
        StubURLProtocol.respond(
            path: "/api/worktrees", status: 400, json: #"{"error":"not a git repository"}"#
        )
        let store = makeStore()
        store.select(Workspace(path: "/p/notes"))
        await store.load()

        XCTAssertTrue(store.workspaceWorktreeNames.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.shownRooms.map(\.id), ["r"])
    }

    // MARK: Archive search

    func testArchiveSearchFindsRoomParticipantModelDecisionAndPostText() async {
        stubEngine(
            rooms: "[]",
            archive: """
            [{ "id": "alpha", "name": "Release Train",
               "participants": [{"name":"builder","persona":"implementor","model":"openai-codex/gpt-5.6-terra"}],
               "log": [],
               "decisions": [{"key":"api-shape","summary":"Choose the wire format","openedBy":"builder"}] },
             { "id": "beta", "name": "Quiet Room", "participants": [],
               "log": [{"id":"m1","from":"reviewer","to":["human"],"text":"The migration is complete","ts":2}] }]
            """,
            worktrees: "[]"
        )
        let store = makeStore()
        await store.load()
        store.tab = .history

        for (query, expectedID) in [
            ("release", "alpha"), ("BUILDER", "alpha"), ("5.6-terra", "alpha"),
            ("wire format", "alpha"), ("migration is complete", "beta"), ("reviewer", "beta")
        ] {
            store.historyQuery = query
            XCTAssertEqual(store.shownRooms.map(\.id), [expectedID], "Archive search should match \(query)")
        }
    }

    func testArchiveSearchDoesNotFilterLiveRooms() async {
        stubEngine(
            rooms: "[\(room(id: "live", git: "/p/kild"))]",
            archive: "[]",
            worktrees: "[]"
        )
        let store = makeStore()
        await store.load()
        store.historyQuery = "does-not-match"

        XCTAssertEqual(store.shownRooms.map(\.id), ["live"], "An inactive archive query must not hide live rooms")
    }

    // MARK: The open list

    func testOpeningAWorkspaceSelectsItAndPersistsTheList() {
        let store = makeStore()
        XCTAssertTrue(store.workspaces.isEmpty)

        store.open(Workspace(path: "/p/kild"))
        XCTAssertEqual(store.workspaces.map(\.path), ["/p/kild"])
        XCTAssertEqual(store.selectedWorkspace?.path, "/p/kild")

        // A relaunch restores both the list and the selection.
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.workspaces.map(\.path), ["/p/kild"])
        XCTAssertEqual(relaunched.selectedWorkspace?.path, "/p/kild")
    }

    func testOpeningTheSameFolderTwiceIsOneEntry() {
        let store = makeStore()
        store.open(Workspace(path: "/p/kild"))
        store.open(Workspace(path: "/p/kild/"))

        XCTAssertEqual(store.workspaces.count, 1)
    }

    /// A main checkout and one of its worktrees are two independent entries — the
    /// thing the unique-name registry structurally could not hold.
    func testTwoCheckoutsOfOneRepoCoexist() {
        let store = makeStore()
        store.open(Workspace(path: "/p/kild"))
        store.open(Workspace(path: "/p/kild/.worktrees/fix"))

        XCTAssertEqual(store.workspaces.map(\.name), ["kild", "fix"])
        XCTAssertEqual(store.selectedWorkspace?.name, "fix")
    }

    func testSelectingWorkspacesRestoresTheirRoomSelectionAndTab() {
        let first = Workspace(path: "/p/first")
        let second = Workspace(path: "/p/second")
        WorkspaceContextStore.save([
            first.path: WorkspaceContext(selectedRoomID: "first-room", roomsTab: .live, historyQuery: ""),
            second.path: WorkspaceContext(selectedRoomID: "second-room", roomsTab: .history, historyQuery: "reviewer")
        ], to: defaults)
        let store = makeStore()

        store.open(first)
        XCTAssertEqual(store.selection, "first-room", "first workspace applies its saved room")
        XCTAssertEqual(store.tab, .live, "first workspace applies its saved tab")
        store.open(second)
        XCTAssertEqual(store.selection, "second-room", "second workspace does not inherit the first room")
        XCTAssertEqual(store.tab, .history, "second workspace restores history")
        XCTAssertEqual(store.historyQuery, "reviewer", "archive search belongs to the workspace context")
        store.select(first)
        XCTAssertEqual(store.selection, "first-room", "returning restores the first selection")
        XCTAssertEqual(store.historyQuery, "", "returning restores the first workspace's archive search")
    }

    func testClosingAWorkspaceEvictsItsContext() {
        let workspace = Workspace(path: "/p/kild")
        WorkspaceContextStore.save([workspace.path: WorkspaceContext(selectedRoomID: "room")], to: defaults)
        let store = makeStore()
        store.open(workspace)
        store.close(workspace)

        XCTAssertNil(store.contexts[workspace.path], "closing a workspace must not retain stale UI state")
        XCTAssertNil(makeStore().contexts[workspace.path], "eviction persists across relaunch")
    }

    func testClosingTheSelectedWorkspaceFallsBackToAll() {
        let store = makeStore()
        store.open(Workspace(path: "/p/kild"))
        store.close(Workspace(path: "/p/kild"))

        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertNil(store.selectedWorkspace)
        // …and it stays gone across a relaunch; nothing was unregistered engine-side.
        XCTAssertTrue(makeStore().workspaces.isEmpty)
    }

    /// A workspace whose folder was deleted on disk is still a list entry — it simply
    /// matches no rooms. Nothing to reconcile, because nothing was registered.
    func testWorkspaceWhoseFolderIsGoneShowsNoRoomsAndNoError() async {
        stubEngine(rooms: "[\(room(id: "r", git: "/p/kild"))]", archive: "[]", worktrees: "[]")
        let store = makeStore()
        store.select(Workspace(path: "/p/deleted-yesterday"))
        await store.load()

        XCTAssertTrue(store.shownRooms.isEmpty)
        XCTAssertNil(store.error)
    }

    // MARK: Helpers

    private func makeStore() -> KildStore {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let engine = EngineClient(urlSession: URLSession(configuration: config))
        return KildStore(engine: engine, defaults: defaults)
    }

    private func stubEngine(rooms: String, archive: String, worktrees: String?) {
        StubURLProtocol.respond(path: "/api/health", status: 200, json: #"{"ok":true,"bootId":"b"}"#)
        StubURLProtocol.respond(path: "/api/rooms/live", status: 200, json: rooms)
        StubURLProtocol.respond(path: "/api/rooms/archive", status: 200, json: archive)
        if let worktrees {
            StubURLProtocol.respond(path: "/api/worktrees", status: 200, json: worktrees)
        }
    }

    private func room(id: String, git: String, worktree: String? = nil) -> String {
        """
        { "id": "\(id)", "name": "\(id)", "participants": [], "log": [],
          "git": {"path": "\(git)"}
          \(worktree.map { #", "worktree": "\#($0)""# } ?? "") }
        """
    }
}
