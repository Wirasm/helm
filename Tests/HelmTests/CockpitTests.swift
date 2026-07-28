import XCTest

@testable import Helm

/// A stand-in engine. Every method returns a canned value or throws a canned error, and
/// records that it was called — which is the whole reason `KildAPI` is a protocol: the
/// cockpit's state transitions are the part most likely to be wrong, and they are only
/// testable if the backend can be held still.
final class StubKildAPI: KildAPI, @unchecked Sendable {

    // canned responses
    var healthResponse = Health(ok: true, bootId: "boot-1")
    var identities: [Kild] = []
    var status: [Kild] = []
    var archived: [ArchivedKild] = []
    var messageLog: [Message] = []
    var report = LandFixture.landable()
    var personaList: [String] = []

    // canned failures — set one and the matching call throws instead of returning
    var healthError: Error?
    var identitiesError: Error?
    var statusError: Error?
    var archiveError: Error?

    // recorded calls
    private(set) var healthCalls = 0
    private(set) var kildsCalls = 0
    private(set) var statusCalls = 0
    private(set) var archiveCalls = 0
    private(set) var sent: [(recipients: [String], text: String, kild: Kild.ID)] = []
    private(set) var stopped: [Kild.ID] = []

    func health() async throws -> Health {
        healthCalls += 1
        if let healthError { throw healthError }
        return healthResponse
    }

    func kilds() async throws -> [Kild] {
        kildsCalls += 1
        if let identitiesError { throw identitiesError }
        return identities
    }

    func kildsStatus() async throws -> [Kild] {
        statusCalls += 1
        if let statusError { throw statusError }
        return status
    }

    func archive() async throws -> [ArchivedKild] {
        archiveCalls += 1
        if let archiveError { throw archiveError }
        return archived
    }

    func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { messageLog }

    func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {
        sent.append((recipients: recipients, text: text, kild: kild))
    }

    func landDryRun(_ kild: Kild.ID) async throws -> LandReport { report }
    func land(_ kild: Kild.ID) async throws -> LandReport { report }
    func delete(_ kild: Kild.ID) async throws {}

    func stop(_ kild: Kild.ID) async throws { stopped.append(kild) }
    func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
    func personas() async throws -> [String] { personaList }
}

/// The cockpit's state transitions: how the two halves of the split listing fold together,
/// what a restarted engine costs, and what survives a failed call.
@MainActor
final class CockpitTests: XCTestCase {

    // MARK: helpers

    private func agent(
        _ handle: String,
        idle: Bool? = nil,
        stopped: Bool? = nil,
        cost: Double? = nil
    ) -> Agent {
        Agent(handle: handle, ownership: .owned, idle: idle, stopped: stopped, cost: cost)
    }

    /// Identity shape — what the cheap listing carries. No git, no totals, by construction.
    private func identity(
        _ name: String,
        id: String? = nil,
        agents: [Agent] = [],
        orphan: Bool? = nil
    ) -> Kild {
        Kild(id: id ?? name, name: name, cwd: "/repo", agents: agents, orphan: orphan)
    }

    /// Status shape — the costly half. Carries identity too, which is exactly the trap
    /// `apply(status:to:)` exists to avoid.
    private func status(
        _ name: String,
        id: String? = nil,
        agents: [Agent] = [],
        ahead: Int? = nil,
        changed: [String]? = nil,
        tokens: Int = 0,
        cost: Double = 0,
        landedSha: String? = nil,
        landed: LandedSummary? = nil
    ) -> Kild {
        Kild(
            id: id ?? name,
            name: name,
            cwd: "/repo",
            agents: agents,
            git: GitFixture.measured(ahead: ahead ?? 0, changedFiles: changed ?? []),
            totals: CostTotals(tokens: tokens, cost: cost),
            landedSha: landedSha,
            landed: landed
        )
    }

    private func archived(_ name: String, endedAt: Double? = nil) -> ArchivedKild {
        ArchivedKild(id: name, name: name, agents: [], endedAt: endedAt)
    }

    private func cockpit(_ api: StubKildAPI) -> Cockpit { Cockpit(api: api) }

    // MARK: merge — identity folded into what we hold

    /// The costly half runs on a slower cadence, so every cheap poll in between must carry
    /// the git it already fetched. Dropping it would blank the git column until the next
    /// costly poll and flicker the sidebar between "3 ahead" and nothing at the polling
    /// ratio.
    func testAnIdentityRefreshKeepsTheGitAlreadyFetched() {
        let held = [
            status("a", ahead: 3, changed: ["Sidebar.swift"], tokens: 900, cost: 1.25,
                   landedSha: "abc123", landed: LandedSummary(commits: 2, files: 7))
        ]
        let merged = Cockpit.merge(identities: [identity("a")], into: held)

        XCTAssertEqual(merged.first?.git?.ahead, 3)
        XCTAssertEqual(merged.first?.git?.changedFiles, ["Sidebar.swift"])
        XCTAssertEqual(merged.first?.totals, CostTotals(tokens: 900, cost: 1.25))
        XCTAssertEqual(merged.first?.landedSha, "abc123")
        XCTAssertEqual(merged.first?.landed, LandedSummary(commits: 2, files: 7))
    }

    /// The other side of the same merge: identity owns agents, so the fresher roster wins
    /// even though the stale one is sitting right there in what we hold.
    func testAnIdentityRefreshTakesTheFreshAgents() {
        let held = [status("a", agents: [agent("coder")], ahead: 1)]
        let fresh = identity("a", agents: [agent("coder", idle: true), agent("reviewer")])
        let merged = Cockpit.merge(identities: [fresh], into: held)

        XCTAssertEqual(merged.first?.agents.map(\.handle), ["coder", "reviewer"])
        XCTAssertTrue(merged.first?.agents.first?.isIdle == true)
    }

    /// Identity is authoritative for existence. A kild the engine no longer lists is gone,
    /// and the status we hold for it goes with it — keeping the row would show a kild that
    /// stopped, with git that can never update again.
    func testAKildAbsentFromTheIdentityListingIsDropped() {
        let held = [status("a", ahead: 1), status("b", ahead: 2)]
        let merged = Cockpit.merge(identities: [identity("b")], into: held)

        XCTAssertEqual(merged.map(\.id), ["b"])
    }

    func testABrandNewKildArrivesWithNoGit() {
        let merged = Cockpit.merge(identities: [identity("new")], into: [])

        XCTAssertEqual(merged.map(\.id), ["new"])
        XCTAssertNil(merged.first?.git)
        XCTAssertNil(merged.first?.totals)
        XCTAssertNil(merged.first?.landedSha)
    }

    /// The listing's order is the engine's, and it is the order the column renders in.
    func testMergeFollowsTheOrderOfTheIdentityListing() {
        let held = [status("a"), status("b"), status("c")]
        let merged = Cockpit.merge(identities: [identity("c"), identity("a")], into: held)

        XCTAssertEqual(merged.map(\.id), ["c", "a"])
    }

    // MARK: apply — status folded into what we hold

    func testStatusBringsInGitAndTotals() {
        let held = [identity("a", agents: [agent("coder")])]
        let fresh = status("a", ahead: 4, tokens: 120, cost: 0.5,
                           landedSha: "def456", landed: LandedSummary(commits: 1, files: 3))
        let applied = Cockpit.apply(status: [fresh], to: held)

        XCTAssertEqual(applied.first?.git?.ahead, 4)
        XCTAssertEqual(applied.first?.totals, CostTotals(tokens: 120, cost: 0.5))
        XCTAssertEqual(applied.first?.landedSha, "def456")
        XCTAssertEqual(applied.first?.landed, LandedSummary(commits: 1, files: 3))
    }

    /// The subtle one. The status listing carries identity too, and taking it wholesale
    /// would roll the roster back to whenever the slow poll started — an agent that went
    /// idle in between would silently stop asking for you. The cheap listing runs more
    /// often, so its agents are the fresher truth and must survive the costly half landing
    /// on top of them.
    func testStatusKeepsTheAgentsFromTheCheapListing() {
        let held = [identity("a", agents: [agent("coder", idle: true), agent("reviewer")])]
        // A snapshot taken before `coder` finished its turn — stale by one cheap poll.
        let stale = status("a", agents: [agent("coder", idle: nil)], ahead: 2)
        let applied = Cockpit.apply(status: [stale], to: held)

        XCTAssertEqual(applied.first?.agents.map(\.handle), ["coder", "reviewer"])
        XCTAssertTrue(applied.first?.agents.first?.isIdle == true,
                      "a stale status roster must not un-idle an agent that is waiting on you")
        XCTAssertEqual(applied.first?.git?.ahead, 2)
    }

    /// The same rule stated as the number the workspace bar shows: a costly refresh landing
    /// on top of a fresh roster must not change how many agents are asking for you.
    func testAStatusRefreshDoesNotChangeTheWaitingCount() async {
        let api = StubKildAPI()
        api.identities = [identity("a", agents: [agent("coder", idle: true)])]
        api.status = [status("a", agents: [agent("coder", idle: nil)], ahead: 1)]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        XCTAssertEqual(cockpit.waitingCount, 1)

        await cockpit.refreshStatus()
        XCTAssertEqual(cockpit.waitingCount, 1)
        XCTAssertEqual(cockpit.kilds.first?.git?.ahead, 1)
    }

    /// Status must not resurrect. A kild missing from what we hold vanished between the two
    /// calls, and adding it back from the slower half would put a stopped kild on screen —
    /// with git, which makes it look more alive than the ones that exist.
    func testStatusForAKildWeNoLongerHoldIsDropped() {
        let held = [identity("a")]
        let applied = Cockpit.apply(status: [status("a", ahead: 1), status("ghost", ahead: 9)],
                                    to: held)

        XCTAssertEqual(applied.map(\.id), ["a"])
    }

    /// Status arrives on its own cadence and can miss a kild the cheap listing just added.
    /// That kild keeps its row and simply has no git yet — it is not dropped, because
    /// identity, not status, decides existence.
    func testAHeldKildWithNoStatusYetSurvivesUntouched() {
        let held = [identity("a", agents: [agent("coder")]), identity("fresh")]
        let applied = Cockpit.apply(status: [status("a", ahead: 1)], to: held)

        XCTAssertEqual(applied.map(\.id), ["a", "fresh"])
        XCTAssertNil(applied.last?.git)
    }

    func testStatusLeavesIdentityFieldsAlone() {
        let held = [Kild(id: "a", name: "sidebar", cwd: "/repo", worktree: "kild/sidebar",
                         base: "development", agents: [], orphan: false)]
        let applied = Cockpit.apply(status: [status("a", ahead: 1)], to: held)

        XCTAssertEqual(applied.first?.name, "sidebar")
        XCTAssertEqual(applied.first?.worktree, "kild/sidebar")
        XCTAssertEqual(applied.first?.base, "development")
    }

    // MARK: archive ordering

    func testArchivesSortNewestFirst() {
        let sorted = [archived("old", endedAt: 100), archived("new", endedAt: 300),
                      archived("mid", endedAt: 200)]
            .sorted(by: Cockpit.newestFirst)

        XCTAssertEqual(sorted.map(\.name), ["new", "mid", "old"])
    }

    /// `endedAt` is absent on archives written before the field existed, and there is
    /// deliberately no fallback — the log that once carried a timestamp is no longer in the
    /// listing, so any substitute would be a guess rendered as a fact. Sorting them last is
    /// the honest position: we do not know when they ended, so we do not claim one.
    func testClocklessArchivesSortLastAndTieBreakByName() {
        let sorted = [archived("zulu"), archived("alpha"), archived("timed", endedAt: 1)]
            .sorted(by: Cockpit.newestFirst)

        XCTAssertEqual(sorted.map(\.name), ["timed", "alpha", "zulu"])
    }

    func testClocklessArchivesStayBelowEvenTheOldestTimedOne() {
        let sorted = [archived("clockless"), archived("ancient", endedAt: 0)]
            .sorted(by: Cockpit.newestFirst)

        XCTAssertEqual(sorted.map(\.name), ["ancient", "clockless"])
    }

    func testRefreshingTheArchiveSortsIt() async {
        let api = StubKildAPI()
        api.archived = [archived("old", endedAt: 1), archived("new", endedAt: 2)]

        let cockpit = cockpit(api)
        await cockpit.refreshArchive()

        XCTAssertEqual(cockpit.archive.map(\.name), ["new", "old"])
    }

    // MARK: boot identity

    /// A changed `bootId` means the engine we were talking to is gone. What we hold is not
    /// merely stale — the ids in it describe objects from a dead process, and a reused id
    /// would point at something else entirely. Clearing is the only honest response.
    func testARestartedEngineClearsEverythingHeld() async {
        let api = StubKildAPI()
        api.identities = [identity("a", agents: [agent("coder", idle: true)])]
        api.archived = [archived("done", endedAt: 1)]

        let cockpit = cockpit(api)
        await cockpit.checkBoot()
        await cockpit.refreshIdentities()
        await cockpit.refreshArchive()
        XCTAssertFalse(cockpit.kilds.isEmpty)
        XCTAssertFalse(cockpit.archive.isEmpty)

        api.healthResponse = Health(ok: true, bootId: "boot-2")
        await cockpit.checkBoot()

        XCTAssertTrue(cockpit.kilds.isEmpty)
        XCTAssertTrue(cockpit.archive.isEmpty)
        XCTAssertEqual(cockpit.bootId, "boot-2")
        XCTAssertEqual(cockpit.waitingCount, 0)
    }

    func testAnUnchangedBootIdLeavesStateAlone() async {
        let api = StubKildAPI()
        api.identities = [identity("a")]
        api.archived = [archived("done", endedAt: 1)]

        let cockpit = cockpit(api)
        await cockpit.checkBoot()
        await cockpit.refreshIdentities()
        await cockpit.refreshArchive()

        await cockpit.checkBoot()

        XCTAssertEqual(cockpit.kilds.map(\.id), ["a"])
        XCTAssertEqual(cockpit.archive.map(\.id), ["done"])
        XCTAssertEqual(cockpit.bootId, "boot-1")
    }

    /// Learning the boot id for the first time is not a restart. Clearing here would throw
    /// away whatever the first refresh raced ahead and fetched.
    func testTheFirstBootIdIsRecordedWithoutClearing() async {
        let api = StubKildAPI()
        api.identities = [identity("a")]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        await cockpit.checkBoot()

        XCTAssertEqual(cockpit.kilds.map(\.id), ["a"])
        XCTAssertEqual(cockpit.bootId, "boot-1")
    }

    // MARK: failure

    /// The engine's own words, kept intact. A refusal like *"refusing: 3 commits not
    /// reachable from base"* is the whole answer; re-deriving something worse from a status
    /// code would throw away the only useful part.
    func testAFailedIdentityRefreshKeepsTheKildsAndLabelsTheError() async {
        let api = StubKildAPI()
        api.identities = [identity("a", agents: [agent("coder", idle: true)])]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()

        api.identitiesError = KildAPIError.engine("seat required")
        await cockpit.refreshIdentities()

        XCTAssertEqual(cockpit.kilds.map(\.id), ["a"], "stale-but-labelled beats empty")
        XCTAssertEqual(cockpit.waitingCount, 1)
        XCTAssertEqual(cockpit.lastError, "seat required")
    }

    func testAFailedStatusRefreshKeepsTheGitItAlreadyHas() async {
        let api = StubKildAPI()
        api.identities = [identity("a")]
        api.status = [status("a", ahead: 5)]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()

        api.statusError = KildAPIError.http(500)
        await cockpit.refreshStatus()

        XCTAssertEqual(cockpit.kilds.first?.git?.ahead, 5)
        XCTAssertEqual(cockpit.lastError, "engine returned HTTP 500")
    }

    func testAFailedArchiveRefreshKeepsTheArchive() async {
        let api = StubKildAPI()
        api.archived = [archived("done", endedAt: 1)]

        let cockpit = cockpit(api)
        await cockpit.refreshArchive()

        api.archiveError = KildAPIError.engine("archive unreadable")
        await cockpit.refreshArchive()

        XCTAssertEqual(cockpit.archive.map(\.id), ["done"])
        XCTAssertEqual(cockpit.lastError, "archive unreadable")
    }

    func testAFailedHealthCheckDoesNotClearState() async {
        let api = StubKildAPI()
        api.identities = [identity("a")]

        let cockpit = cockpit(api)
        await cockpit.checkBoot()
        await cockpit.refreshIdentities()

        api.healthError = KildAPIError.engine("connection refused")
        await cockpit.checkBoot()

        XCTAssertEqual(cockpit.kilds.map(\.id), ["a"])
        XCTAssertEqual(cockpit.bootId, "boot-1")
        XCTAssertEqual(cockpit.lastError, "connection refused")
    }

    /// A recovered call must clear the banner. An error left standing after the picture came
    /// back would tell the operator their data is stale when it is current — the same lie as
    /// showing stale data as fresh, in the other direction.
    func testARecoveredRefreshClearsThePreviousError() async {
        let api = StubKildAPI()
        api.identitiesError = KildAPIError.engine("seat required")

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        XCTAssertEqual(cockpit.lastError, "seat required")

        api.identitiesError = nil
        api.identities = [identity("a")]
        await cockpit.refreshIdentities()

        XCTAssertNil(cockpit.lastError)
        XCTAssertEqual(cockpit.kilds.map(\.id), ["a"])
    }

    func testARecoveredStatusRefreshClearsThePreviousError() async {
        let api = StubKildAPI()
        api.statusError = KildAPIError.http(503)

        let cockpit = cockpit(api)
        await cockpit.refreshStatus()
        XCTAssertNotNil(cockpit.lastError)

        api.statusError = nil
        await cockpit.refreshStatus()

        XCTAssertNil(cockpit.lastError)
    }

    func testARecoveredArchiveRefreshClearsThePreviousError() async {
        let api = StubKildAPI()
        api.archiveError = KildAPIError.http(503)

        let cockpit = cockpit(api)
        await cockpit.refreshArchive()
        XCTAssertNotNil(cockpit.lastError)

        api.archiveError = nil
        await cockpit.refreshArchive()

        XCTAssertNil(cockpit.lastError)
    }

    // MARK: derivations

    func testWaitingCountReadsEveryHeldKild() async {
        let api = StubKildAPI()
        api.identities = [
            identity("a", agents: [agent("one", idle: true), agent("two")]),
            identity("b", agents: [agent("three", idle: true)]),
        ]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()

        XCTAssertEqual(cockpit.waitingCount, 2)
    }

    func testCollisionsAreDerivedFromTheGitTheStatusRefreshBrought() async {
        let api = StubKildAPI()
        api.identities = [identity("a"), identity("b")]
        api.status = [status("a", changed: ["Store.swift"]), status("b", changed: ["Store.swift"])]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        XCTAssertTrue(cockpit.collisions.isEmpty, "no git fetched yet, so nothing to intersect")

        await cockpit.refreshStatus()

        XCTAssertEqual(cockpit.collisions["a"]?.first?.other, "b")
        XCTAssertEqual(cockpit.collisions["b"]?.first?.other, "a")
    }

    func testGroupsSplitOrphansFromLiveKilds() async {
        let api = StubKildAPI()
        api.identities = [
            identity("live", agents: [agent("coder")]),
            identity("ghost", orphan: true),
        ]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()

        XCTAssertEqual(cockpit.groups[.live]?.map(\.name), ["live"])
        XCTAssertEqual(cockpit.groups[.orphaned]?.map(\.name), ["ghost"])
    }

    // MARK: the split listing, as it is actually polled

    /// The two halves at their real cadences: identity polls repeatedly between costly ones.
    /// Every one of those cheap polls must leave the git column standing.
    func testRepeatedCheapPollsNeverBlankTheGitColumn() async {
        let api = StubKildAPI()
        api.identities = [identity("a", agents: [agent("coder")])]
        api.status = [status("a", ahead: 3, tokens: 50, cost: 0.1)]

        let cockpit = cockpit(api)
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()

        for _ in 0..<5 {
            await cockpit.refreshIdentities()
            XCTAssertEqual(cockpit.kilds.first?.git?.ahead, 3)
            XCTAssertEqual(cockpit.kilds.first?.totals, CostTotals(tokens: 50, cost: 0.1))
        }

        XCTAssertEqual(api.kildsCalls, 6)
        XCTAssertEqual(api.statusCalls, 1)
    }
}
