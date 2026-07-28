import XCTest

@testable import Helm

/// Everything the workspace bar reports must be scoped to the workspace it is reporting on.
///
/// The bug this guards is not a crash — it is a grammatical sentence made of two facts at
/// different scopes. "2 kilds · $47.10" reads fine whether the money belongs to those two
/// kilds or to every project on the machine, and nobody questions a sentence that parses.
/// The count was scoped and the spend was not.
final class WorkspaceScopeTests: XCTestCase {

    private func kild(_ name: String, cwd: String, cost: Double?, idle: Bool = false)
        -> Kild
    {
        Kild(
            id: name, name: name, cwd: cwd,
            agents: [Agent(handle: "a", ownership: .owned, idle: idle)],
            totals: cost.map { CostTotals(tokens: 1000, cost: $0) })
    }

    @MainActor
    private func store(_ kilds: [Kild], workspace: String?) -> KildStore {
        let suite = "helm.scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = KildStore(api: FixedAPI(kilds: kilds), defaults: defaults, launchKild: nil)
        if let workspace { store.open(Workspace(path: workspace)) }
        return store
    }

    /// The count only includes kilds in the open workspace.
    @MainActor
    func testTheKildCountIsScopedToTheWorkspace() async {
        let store = store(
            [
                kild("mine", cwd: "/repo", cost: 1.0),
                kild("theirs", cwd: "/elsewhere", cost: 40.0),
            ], workspace: "/repo")
        await store.loadIdentities()
        await store.loadStatus()

        XCTAssertEqual(store.shownGroups[.live]?.map(\.name), ["mine"])
    }

    /// The spend must be scoped the same way, or the bar puts a workspace count beside a
    /// machine-wide total in one sentence.
    @MainActor
    func testTheSpendIsScopedToTheSameKildsAsTheCount() async {
        let store = store(
            [
                kild("mine", cwd: "/repo", cost: 1.0),
                kild("theirs", cwd: "/elsewhere", cost: 40.0),
            ], workspace: "/repo")
        await store.loadIdentities()
        await store.loadStatus()

        let live = store.shownGroups[.live] ?? []
        let scopedSpend = live.compactMap(\.totals?.cost).reduce(0, +)
        let machineSpend = store.cockpit.kilds.compactMap(\.totals?.cost).reduce(0, +)

        XCTAssertEqual(scopedSpend, 1.0, accuracy: 0.001)
        XCTAssertEqual(machineSpend, 41.0, accuracy: 0.001, "the unscoped total, for contrast")
        XCTAssertNotEqual(scopedSpend, machineSpend, "which is exactly why it must be scoped")
    }

    /// The waiting count too — a badge that counted every workspace would send you looking
    /// in the wrong project, which is worse than not showing a badge at all.
    @MainActor
    func testTheWaitingCountIsScopedToTheWorkspace() async {
        let store = store(
            [
                kild("mine", cwd: "/repo", cost: nil, idle: false),
                kild("theirs", cwd: "/elsewhere", cost: nil, idle: true),
            ], workspace: "/repo")
        await store.loadIdentities()

        XCTAssertEqual(
            store.waitingCount, 0,
            "the idle agent is in another project; this badge must not point there")
    }

    /// With no workspace open, everything is in scope — the unfiltered view is a real state,
    /// not an error.
    @MainActor
    func testWithNoWorkspaceOpenNothingIsFilteredOut() async {
        let store = store(
            [
                kild("mine", cwd: "/repo", cost: 1.0, idle: true),
                kild("theirs", cwd: "/elsewhere", cost: 40.0, idle: true),
            ], workspace: nil)
        await store.loadIdentities()

        XCTAssertEqual(store.shownGroups[.live]?.count, 2)
        XCTAssertEqual(store.waitingCount, 2)
    }

    private struct FixedAPI: KildAPI {
        let kilds: [Kild]
        func health() async throws -> Health { Health(ok: true, bootId: "b") }
        func kilds() async throws -> [Kild] { kilds }
        func kildsStatus() async throws -> [Kild] { kilds }
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
}
