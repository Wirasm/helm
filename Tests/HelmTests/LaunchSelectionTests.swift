import XCTest

@testable import Helm

/// `--kild <id>` must outrank a restored workspace context.
///
/// **This file previously could not reach its own subject.** `launchKild` read
/// `ProcessInfo.processInfo.arguments` directly, so under `swift test` no `--kild` argument
/// exists and the value was permanently `nil` — making every line that guards it
/// structurally unreachable by the entire suite. The two tests here passed while proving
/// only the *no-flag* path, under names claiming the opposite.
///
/// That is worse than having no test. A missing test is a known gap; a test that cannot
/// reach its subject reports the branch as covered. The flag is injected now, so these
/// exercise the real thing.
final class LaunchSelectionTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let suite = "helm.launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Persist a workspace whose saved context selects `selected`.
    @discardableResult
    private func withSavedContext(selecting selected: String?, in defaults: UserDefaults)
        -> Workspace
    {
        let workspace = Workspace(path: "/repo")
        WorkspacePersistence.save([workspace], to: defaults)
        WorkspacePersistence.saveSelection(workspace, to: defaults)
        var context = WorkspaceContext()
        context.selectedKildID = selected
        WorkspaceContextStore.save([workspace.path: context], to: defaults)
        return workspace
    }

    // MARK: - The branch that was unreachable

    /// The actual regression: `selection` was set from the flag, then `applyContext`
    /// overwrote it unconditionally from the saved context.
    @MainActor
    func testAnExplicitLaunchKildBeatsARestoredContext() {
        let store = defaults()
        withSavedContext(selecting: "previously-selected", in: store)

        let cockpit = KildStore(api: EmptyAPI(), defaults: store, launchKild: "launched-kild")

        XCTAssertEqual(
            cockpit.selection, "launched-kild",
            "the flag is explicit intent; the context is only what happened last time")
    }

    /// Without a flag the context still wins — the fix must not break restoration.
    @MainActor
    func testARestoredContextWinsWhenNoFlagWasGiven() {
        let store = defaults()
        withSavedContext(selecting: "previously-selected", in: store)
        let cockpit = KildStore(api: EmptyAPI(), defaults: store, launchKild: nil)
        XCTAssertEqual(cockpit.selection, "previously-selected")
    }

    @MainActor
    func testWithNeitherFlagNorContextNothingIsSelected() {
        let cockpit = KildStore(api: EmptyAPI(), defaults: defaults(), launchKild: nil)
        XCTAssertNil(cockpit.selection)
    }

    @MainActor
    func testAnExplicitLaunchKildAppliesWithNoSavedContext() {
        let cockpit = KildStore(api: EmptyAPI(), defaults: defaults(), launchKild: "k-1")
        XCTAssertEqual(cockpit.selection, "k-1")
    }

    // MARK: - The archive tab flip, also previously unreachable

    /// `--kild` naming an ARCHIVED kild lands on History rather than an empty Live tab.
    @MainActor
    func testALaunchKildThatIsArchivedFlipsToHistory() async {
        let cockpit = KildStore(
            api: ArchiveOnlyAPI(archivedID: "gone"), defaults: defaults(), launchKild: "gone")
        XCTAssertEqual(cockpit.tab, .live, "before data arrives there is nothing to decide")

        await cockpit.loadArchive()

        XCTAssertEqual(cockpit.tab, .history)
    }

    /// The second bug the review found: resolution used to run from `loadIdentities()` and
    /// gate on `!kilds.isEmpty || !archive.isEmpty` — treating "live kilds arrived" as proof
    /// data had arrived, when the question needs the ARCHIVE. Identities land first, the OR
    /// passed on a non-empty live list, the lookup found nothing, and it marked itself
    /// resolved anyway. On any engine with a live kild — every real one — the flip never
    /// happened.
    @MainActor
    func testIdentitiesArrivingFirstDoNotConsumeTheResolution() async {
        let cockpit = KildStore(
            api: LiveAndArchivedAPI(liveID: "live-1", archivedID: "gone"),
            defaults: defaults(), launchKild: "gone")

        await cockpit.loadIdentities()  // live kilds arrive; archive still empty
        XCTAssertEqual(cockpit.tab, .live, "nothing to decide on yet")

        await cockpit.loadArchive()  // now the archive is here
        XCTAssertEqual(
            cockpit.tab, .history,
            "resolution must survive an identities load that could not answer it")
    }

    /// It reads the FLAG, not `selection` — a restored context may have replaced the
    /// selection since launch, and flipping to History for a kild nobody named is worse
    /// than not flipping at all.
    @MainActor
    func testTheTabDoesNotFlipForARestoredSelectionThatHappensToBeArchived() async {
        let store = defaults()
        withSavedContext(selecting: "gone", in: store)

        let cockpit = KildStore(
            api: ArchiveOnlyAPI(archivedID: "gone"), defaults: store, launchKild: nil)
        await cockpit.loadArchive()

        XCTAssertEqual(
            cockpit.tab, .live,
            "restoring a selection is not a request to change tabs")
    }

    @MainActor
    func testALaunchKildThatIsLiveStaysOnTheLiveTab() async {
        let cockpit = KildStore(api: EmptyAPI(), defaults: defaults(), launchKild: "k-1")
        await cockpit.loadArchive()
        XCTAssertEqual(cockpit.tab, .live)
    }

    // MARK: - Stubs

    private struct EmptyAPI: KildAPI {
        func health() async throws -> Health { Health(ok: true, bootId: "b") }
        func kilds() async throws -> [Kild] { [] }
        func kildsStatus() async throws -> [Kild] { [] }
        func archive() async throws -> [ArchivedKild] { [] }
        func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { [] }
        func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {}
        func landDryRun(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func land(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func delete(_ kild: Kild.ID) async throws {}
        func stop(_ kild: Kild.ID) async throws {}
        func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
        func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
            AgentTranscript(entries: [], total: 0)
        }
        func personas() async throws -> [String] { [] }
    }

    private struct ArchiveOnlyAPI: KildAPI {
        let archivedID: String
        func health() async throws -> Health { Health(ok: true, bootId: "b") }
        func kilds() async throws -> [Kild] { [] }
        func kildsStatus() async throws -> [Kild] { [] }
        func archive() async throws -> [ArchivedKild] {
            [ArchivedKild(id: archivedID, name: archivedID, agents: [], cwd: "/repo")]
        }
        func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { [] }
        func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {}
        func landDryRun(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func land(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func delete(_ kild: Kild.ID) async throws {}
        func stop(_ kild: Kild.ID) async throws {}
        func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
        func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
            AgentTranscript(entries: [], total: 0)
        }
        func personas() async throws -> [String] { [] }
    }

    /// Live kilds AND an archive — the shape that exposed the premature-resolution bug.
    private struct LiveAndArchivedAPI: KildAPI {
        let liveID: String
        let archivedID: String
        func health() async throws -> Health { Health(ok: true, bootId: "b") }
        func kilds() async throws -> [Kild] {
            [Kild(id: liveID, name: liveID, cwd: "/repo", agents: [])]
        }
        func kildsStatus() async throws -> [Kild] { [] }
        func archive() async throws -> [ArchivedKild] {
            [ArchivedKild(id: archivedID, name: archivedID, agents: [], cwd: "/repo")]
        }
        func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { [] }
        func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {}
        func landDryRun(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func land(_ kild: Kild.ID) async throws -> LandReport { LandFixture.landable() }
        func delete(_ kild: Kild.ID) async throws {}
        func stop(_ kild: Kild.ID) async throws {}
        func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
        func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
            AgentTranscript(entries: [], total: 0)
        }
        func personas() async throws -> [String] { [] }
    }
}
