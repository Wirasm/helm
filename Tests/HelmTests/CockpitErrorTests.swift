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
    private struct PartiallyBrokenAPI: KildAPI {
        var failing: Set<Cockpit.Poll>

        private func check(_ poll: Cockpit.Poll) throws {
            if failing.contains(poll) { throw KildAPIError.engine("\(poll) is down") }
        }

        func health() async throws -> Health {
            try check(.health)
            return Health(ok: true, bootId: "boot-1")
        }
        func kilds() async throws -> [Kild] {
            try check(.identities)
            return [Kild(id: "k", name: "k", cwd: "/repo", agents: [])]
        }
        func kildsStatus() async throws -> [Kild] {
            try check(.status)
            return [Kild(id: "k", name: "k", cwd: "/repo", agents: [], git: GitFixture.measured(ahead: 3))]
        }
        func archive() async throws -> [ArchivedKild] {
            try check(.archive)
            return []
        }
        func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] { [] }
        func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {}
        func landDryRun(_ kild: Kild.ID) async throws -> LandReport { LandReport(ok: true) }
        func land(_ kild: Kild.ID) async throws -> LandReport { LandReport(ok: true) }
        func delete(_ kild: Kild.ID) async throws {}
        func stop(_ kild: Kild.ID) async throws {}
        func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
        func personas() async throws -> [String] { [] }
    }

    /// The exact regression: status fails, identities succeeds, and the status failure must
    /// survive. Previously the second call wiped it.
    @MainActor
    func testASuccessfulCheapPollDoesNotEraseAFailingCostlyOne() async {
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: [.status]))

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
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: [.status]))
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()

        XCTAssertNil(cockpit.kilds.first?.git, "no git arrived")
        XCTAssertNotNil(cockpit.errors[.status], "and the reason is on record")
    }

    @MainActor
    func testEachPollClearsOnlyItsOwnError() async {
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: [.status, .archive]))
        await cockpit.refreshStatus()
        await cockpit.refreshArchive()
        XCTAssertEqual(cockpit.errors.count, 2)

        let healthy = Cockpit(api: PartiallyBrokenAPI(failing: []))
        await healthy.refreshStatus()
        XCTAssertTrue(healthy.errors.isEmpty)
    }

    @MainActor
    func testARecoveredPollClearsItsOwnError() async {
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: [.status]))
        await cockpit.refreshStatus()
        XCTAssertNotNil(cockpit.errors[.status])

        // Same cockpit, engine recovers.
        let recovered = Cockpit(api: PartiallyBrokenAPI(failing: []))
        await recovered.refreshStatus()
        XCTAssertNil(recovered.errors[.status])
    }

    /// A one-line UI still has something to show, without pretending there is only ever
    /// one thing wrong.
    @MainActor
    func testLastErrorSurfacesSomethingWhenAnyPollIsFailing() async {
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: [.archive]))
        await cockpit.refreshArchive()
        XCTAssertNotNil(cockpit.lastError)
    }

    @MainActor
    func testLastErrorIsNilWhenEverythingIsHealthy() async {
        let cockpit = Cockpit(api: PartiallyBrokenAPI(failing: []))
        await cockpit.refreshIdentities()
        await cockpit.refreshStatus()
        await cockpit.refreshArchive()
        await cockpit.checkBoot()
        XCTAssertNil(cockpit.lastError)
    }
}
