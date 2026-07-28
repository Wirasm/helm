import Foundation
import XCTest

@testable import Helm

/// The workspace filter end to end: the store loads kilds from a stubbed engine and narrows
/// them to the open folder — the one behaviour the registry ever bought, now keyed by a path
/// nobody had to register.
///
/// The store is two halves composed rather than merged, and this file tests the seam: the
/// engine half (`cockpit`) is populated through the split polls, the workspace half is
/// persisted locally, and `shownGroups` / `shownArchive` are where the two meet.
@MainActor
final class KildStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var api: FakeKildAPI!

    override func setUpWithError() throws {
        suiteName = "helm-kildstore-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        api = FakeKildAPI()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Filtering

    func testSelectingAWorkspaceFiltersKildsAndDeselectingShowsAll() async {
        api.identities = [
            kild("in", cwd: "/p/kild/sub"),
            kild("sibling", cwd: "/p/kild-ui"),
            kild("elsewhere", cwd: "/p/other")
        ]
        let store = makeStore()
        await load(store)
        XCTAssertEqual(shownLive(store).sorted(), ["elsewhere", "in", "sibling"])

        store.select(Workspace(path: "/p/kild"))
        await load(store)
        // Sibling-prefix collision must not leak in.
        XCTAssertEqual(shownLive(store), ["in"])

        store.select(nil)
        await load(store)
        XCTAssertEqual(shownLive(store).count, 3)
    }

    // REMOVED: testWorktreeRoomsAttributeByNameFromThePathQuery.
    //
    // It asserted that a worktree kild was attributed to the open folder by *name*, via the
    // list `GET /api/worktrees?path=…` returned, and that the query carried a path rather
    // than a registered project name. Both halves are gone: the endpoint was deleted from
    // the engine with no successor, `KildAPI` has no method for it, and `KildStore` no
    // longer exposes `workspaceWorktreeNames`. The behaviour it protected — a kild whose
    // worktree lives under `$KILD_HOME` still belongs to its project folder — survives by a
    // different mechanism (`Kild.cwd` containment) and is covered by
    // `WorkspaceAttributionTests.testAWorktreeKildIsAttributedByCwdNotByWorktreeLocation`,
    // with the orphan case alongside it.

    /// The surviving half of `testNonRepoWorkspaceYieldsNoWorktreeNamesAndNoError`.
    ///
    /// Opening a folder that is no git repo used to 400 on `/api/worktrees`, and the store
    /// had to swallow that without surfacing an engine error. There is no second request
    /// any more, so the guarantee is now structural rather than defensive — worth pinning
    /// anyway, because it is the property the deleted call kept threatening.
    func testANonRepoWorkspaceShowsItsKildsAndReportsNoError() async {
        api.identities = [kild("r", cwd: "/p/notes")]
        let store = makeStore()
        store.select(Workspace(path: "/p/notes"))
        await load(store)

        XCTAssertEqual(shownLive(store), ["r"])
        XCTAssertNil(store.cockpit.lastError, "a folder that is no repo is not an engine failure")
    }

    // MARK: Collisions

    func testCollisionsIntersectChangedFilesAcrossLiveKilds() async {
        api.identities = [
            kild("a", name: "alpha", cwd: "/p/a"),
            kild("b", name: "beta", cwd: "/p/b"),
            kild("c", name: "charlie", cwd: "/p/c"),
            kild("d", name: "delta", cwd: "/p/d")
        ]
        api.status = [
            kild("a", name: "alpha", cwd: "/p/a",
                 git: GitFixture.measured(changedFiles: ["Sources/A.swift", "shared.swift"])),
            kild("b", name: "beta", cwd: "/p/b",
                 git: GitFixture.measured(changedFiles: ["shared.swift", "Tests/B.swift"])),
            kild("c", name: "charlie", cwd: "/p/c",
                 git: GitFixture.measured(
                    changedFiles: ["shared.swift", "shared.swift", "Sources/A.swift"])),
            kild("d", name: "delta", cwd: "/p/d",
                 git: GitFixture.measured(changedFiles: ["elsewhere.swift"]))
        ]
        let store = makeStore()
        await load(store)

        XCTAssertEqual(store.cockpit.collisions["a"], [
            Collision(other: "b", otherName: "beta", files: ["shared.swift"]),
            Collision(other: "c", otherName: "charlie", files: ["Sources/A.swift", "shared.swift"])
        ])
        XCTAssertNil(store.cockpit.collisions["d"])

        // Collision scope is every live kild, even when the workspace hides the peers.
        store.select(Workspace(path: "/p/a"))
        store.selection = "a"
        await load(store)
        XCTAssertEqual(shownLive(store), ["a"])
        XCTAssertEqual(store.selectedCollisions.map(\.otherName), ["beta", "charlie"])
    }

    /// A failed git probe returns `changedFiles: []` alongside its `error`, which is
    /// indistinguishable from a clean tree unless someone reads `error`. Deriving from it
    /// would report "no collision" — the most reassuring possible answer — from a
    /// measurement that never happened.
    func testCollisionsIgnoreGitFailureOnEitherKild() async {
        // The fixture's own defaults, plus the files a real failure can still carry: the
        // point is that `error` disqualifies the probe regardless of what else is in it.
        var brokenProbe = GitFixture.failed("not a repository")
        brokenProbe.changedFiles = ["shared.swift"]

        api.identities = [kild("good", cwd: "/p/good"), kild("failed", cwd: "/p/failed")]
        api.status = [
            kild("good", cwd: "/p/good",
                 git: GitFixture.measured(changedFiles: ["shared.swift"])),
            kild("failed", cwd: "/p/failed", git: brokenProbe)
        ]
        let store = makeStore()
        await load(store)

        XCTAssertNil(store.cockpit.collisions["good"])
        XCTAssertNil(store.cockpit.collisions["failed"])
    }

    // MARK: Archive search

    /// Ported from `testArchiveSearchFindsRoomParticipantModelDecisionAndPostText`.
    ///
    /// Two of those five no longer have anything to match against. **Decisions were deleted
    /// as a concept** — there is no `decisions` field on the wire and no `openDecisions`
    /// anywhere in helm. **Post text cannot be searched** because `ArchivedKild` carries no
    /// log: shipping every stopped kild's conversation in a listing was the engine's most
    /// expensive route and it was removed, so matching prose would mean fetching every
    /// archived kild's messages — exactly the cost the removal bought back. See
    /// `ArchivedKild.matchesSearch` for what the listing does carry.
    func testArchiveSearchFindsKildNameAgentHandleAndModel() async {
        api.archived = [
            ArchivedKild(
                id: "alpha", name: "Release Train",
                agents: [
                    Agent(handle: "builder", ownership: .owned, persona: "implementor",
                          model: "openai-codex/gpt-5.6-terra")
                ],
                endedAt: 2),
            ArchivedKild(
                id: "beta", name: "Quiet Room",
                agents: [Agent(handle: "reviewer", ownership: .owned)],
                endedAt: 1)
        ]
        let store = makeStore()
        await load(store)
        store.tab = .history

        for (query, expectedID) in [
            ("release", "alpha"), ("BUILDER", "alpha"), ("5.6-terra", "alpha"),
            ("implementor", "alpha"), ("reviewer", "beta")
        ] {
            store.historyQuery = query
            XCTAssertEqual(
                store.shownArchive.map(\.id), [expectedID], "Archive search should match \(query)")
        }
        store.historyQuery = ""
        XCTAssertEqual(store.shownArchive.count, 2, "clearing search restores the archive")
    }

    func testArchiveSearchDoesNotFilterLiveKilds() async {
        api.identities = [kild("live", cwd: "/p/kild")]
        let store = makeStore()
        await load(store)
        store.historyQuery = "does-not-match"

        XCTAssertEqual(
            shownLive(store), ["live"], "An inactive archive query must not hide live kilds")
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

    func testSelectingWorkspacesRestoresTheirKildSelectionAndTab() {
        let first = Workspace(path: "/p/first")
        let second = Workspace(path: "/p/second")
        WorkspaceContextStore.save([
            first.path: WorkspaceContext(
                selectedKildID: "first-kild", kildsTab: .live, historyQuery: "",
                expandedKilds: ["first-kild"]
            ),
            second.path: WorkspaceContext(
                selectedKildID: "second-kild", kildsTab: .history, historyQuery: "reviewer",
                expandedKilds: ["second-kild"]
            )
        ], to: defaults)
        let store = makeStore()

        store.open(first)
        XCTAssertEqual(store.selection, "first-kild", "first workspace applies its saved kild")
        XCTAssertEqual(store.tab, .live, "first workspace applies its saved tab")
        XCTAssertEqual(store.expandedKilds, ["first-kild"])
        store.open(second)
        XCTAssertEqual(store.selection, "second-kild", "second workspace does not inherit the first")
        XCTAssertEqual(store.tab, .history, "second workspace restores history")
        XCTAssertEqual(store.historyQuery, "reviewer", "archive search belongs to the workspace context")
        XCTAssertEqual(store.expandedKilds, ["second-kild"])
        store.select(first)
        XCTAssertEqual(store.selection, "first-kild", "returning restores the first selection")
        XCTAssertEqual(store.historyQuery, "", "returning restores the first workspace's archive search")
        XCTAssertEqual(store.expandedKilds, ["first-kild"], "agent disclosure follows workspace context")
    }

    func testClosingAWorkspaceEvictsItsContext() {
        let workspace = Workspace(path: "/p/kild")
        WorkspaceContextStore.save([workspace.path: WorkspaceContext(selectedKildID: "kild")], to: defaults)
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
    /// matches no kilds. Nothing to reconcile, because nothing was registered.
    func testWorkspaceWhoseFolderIsGoneShowsNoKildsAndNoError() async {
        api.identities = [kild("r", cwd: "/p/kild")]
        let store = makeStore()
        store.select(Workspace(path: "/p/deleted-yesterday"))
        await load(store)

        XCTAssertTrue(shownLive(store).isEmpty)
        XCTAssertNil(store.cockpit.lastError)
    }

    // MARK: Helpers

    private func makeStore() -> KildStore {
        KildStore(api: api, defaults: defaults)
    }

    /// One full tick of both halves of the split listing, plus the archive — the cadence
    /// `RootView` drives, collapsed for a test that wants everything present.
    private func load(_ store: KildStore) async {
        await store.loadIdentities()
        await store.loadStatus()
        await store.loadArchive()
    }

    private func shownLive(_ store: KildStore) -> [String] {
        (store.shownGroups[.live] ?? []).map(\.id)
    }

    private func kild(
        _ id: String, name: String? = nil, cwd: String, git: GitStatus? = nil
    ) -> Kild {
        Kild(id: id, name: name ?? id, cwd: cwd, agents: [], git: git)
    }
}
