import XCTest

@testable import Helm

/// Each poll owns its own error.
///
/// A single shared `lastError` was wrong in a way that hid exactly what it existed to
/// reveal: every refresh cleared it on success, so a healthy cheap poll erased a failing
/// costly one. Because the cheap half runs far more often by design, a persistently broken
/// `/api/kilds/status` was un-labelled within one tick — git column permanently blank, no
/// error anywhere.
final class CockpitErrorTests: XCTestCase {

    /// Fails whichever calls you name, succeeds at the rest.

    /// The exact regression: status fails, identities succeeds, and the status failure must
    /// survive. Previously the second call wiped it.
    @MainActor
    func testASuccessfulCheapPollDoesNotEraseAFailingCostlyOne() async {
        let cockpit = Cockpit(api: broken([.status]))

        await cockpit.refreshStatus()
        XCTAssertNotNil(cockpit.errors[.status])

        await cockpit.refreshIdentities()
        XCTAssertNotNil(
            cockpit.errors[.status],
            "the status route is still broken; a healthy identity poll is not evidence otherwise")
        XCTAssertNil(cockpit.errors[.identities])
    }

    /// The blank column the erased error was hiding.
    @MainActor
    func testTheStaleGitColumnIsLabelledRatherThanSilentlyEmpty() async {
        let cockpit = Cockpit(api: broken([.status]))
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()

        XCTAssertNil(cockpit.kilds.first?.git, "no git arrived")
        XCTAssertNotNil(cockpit.errors[.status], "and the reason is on record")
    }

    @MainActor
    func testEachPollClearsOnlyItsOwnError() async {
        let cockpit = Cockpit(api: broken([.status, .archive]))
        await cockpit.refreshStatus()
        await cockpit.refreshArchive()
        XCTAssertEqual(cockpit.errors.count, 2)

        let healthy = Cockpit(api: broken([]))
        await healthy.refreshStatus()
        XCTAssertTrue(healthy.errors.isEmpty)
    }

    @MainActor
    func testARecoveredPollClearsItsOwnError() async {
        let cockpit = Cockpit(api: broken([.status]))
        await cockpit.refreshStatus()
        XCTAssertNotNil(cockpit.errors[.status])

        // Same cockpit, engine recovers.
        let recovered = Cockpit(api: broken([]))
        await recovered.refreshStatus()
        XCTAssertNil(recovered.errors[.status])
    }

    /// A one-line UI still has something to show, without pretending there is only ever
    /// one thing wrong.
    @MainActor
    func testLastErrorSurfacesSomethingWhenAnyPollIsFailing() async {
        let cockpit = Cockpit(api: broken([.archive]))
        await cockpit.refreshArchive()
        XCTAssertNotNil(cockpit.lastError)
    }

    @MainActor
    func testLastErrorIsNilWhenEverythingIsHealthy() async {
        let cockpit = Cockpit(api: broken([]))
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()
        await cockpit.refreshArchive()
        await cockpit.checkBoot()
        XCTAssertNil(cockpit.lastError)
    }

    // MARK: - Fixtures

    private func broken(_ polls: Set<Cockpit.Poll>) -> FakeKildAPI {
        let api = FakeKildAPI(
            kilds: [Kild(id: "k", name: "k", cwd: "/repo", agents: [])],
            status: [Kild(id: "k", name: "k", cwd: "/repo", agents: [], git: GitFixture.measured(ahead: 3))])
        api.failing = polls
        return api
    }
}
