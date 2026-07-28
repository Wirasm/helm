import XCTest

@testable import Helm

/// The store's disposal action — three outcomes, only one of which is an error.
final class DisposalActionTests: XCTestCase {

    private func scratch() -> UserDefaults {
        let suite = "helm.dispose.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func kild(_ name: String, worktree: String? = nil) -> Kild {
        Kild(id: name, name: name, cwd: "/repo", worktree: worktree ?? name, agents: [])
    }

    @MainActor
    func testASuccessfulDisposalIsReportedWithTheEnginesOwnRecord() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.dispose(kild("t"), force: false)

        guard case let .removed(_, report) = store.lastDisposal else {
            return XCTFail("expected removal, got \(String(describing: store.lastDisposal))")
        }
        XCTAssertTrue(report.branchKept)
        XCTAssertEqual(api.deleted.map(\.force), [false])
    }

    /// A refusal is the guard working, not a failure of helm's — and the engine's reason is
    /// what tells the operator what is at stake.
    @MainActor
    func testARefusalKeepsTheEnginesReason() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        api.failDelete = .engine("refusing: 3 commits not reachable from base")
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.dispose(kild("t"), force: false)

        XCTAssertEqual(
            store.lastDisposal,
            .refused(kild: "t", reason: "refusing: 3 commits not reachable from base"))
    }

    /// The dangerous case. A timeout is NOT a refusal: the tree may be gone. Reporting it as
    /// failure would invite a retry of something that already happened.
    @MainActor
    func testATimeoutIsReportedAsUnknownNotRefused() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        api.failDelete = .outcomeUnknown(verb: "disposal")
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.dispose(kild("t"), force: false)

        guard case let .unknown(_, message) = store.lastDisposal else {
            return XCTFail("a timeout must not read as a refusal")
        }
        XCTAssertTrue(message.contains("check before retrying"))
    }

    /// `force` must reach the engine — it is the only thing that overrides the guard.
    @MainActor
    func testForceIsPassedThrough() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.dispose(kild("t"), force: true)

        XCTAssertEqual(api.deleted.map(\.force), [true])
    }

    /// helm must not remove the kild from local state itself. The next poll reports what the
    /// engine actually holds — asserting an outcome instead of observing one is precisely
    /// the drift this store is built to avoid.
    @MainActor
    func testDisposalRefreshesRatherThanMutatingLocalState() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        await store.loadIdentities()
        let before = api.kildsCalls

        await store.dispose(kild("t"), force: false)

        XCTAssertGreaterThan(api.kildsCalls, before, "it re-reads instead of assuming")
    }

    /// Even an unknown outcome refreshes — the poll is the only way to learn whether the
    /// engine finished after we stopped listening.
    @MainActor
    func testAnUnknownOutcomeStillRefreshes() async {
        let api = FakeKildAPI(kilds: [kild("t")])
        api.failDelete = .outcomeUnknown(verb: "disposal")
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        await store.loadIdentities()
        let before = api.kildsCalls

        await store.dispose(kild("t"), force: false)

        XCTAssertGreaterThan(api.kildsCalls, before)
    }

    /// A kild with no worktree offers no gesture at all — the menu says why rather than
    /// producing a refusal the operator could have been spared.
    func testAKildInTheCheckoutOffersNoDisposal() {
        let inPlace = Kild(id: "k", name: "k", cwd: "/repo", worktree: nil, agents: [])
        XCTAssertFalse(Disposal.isDisposable(inPlace))
    }

    /// Every outcome names its kild, so a slow result for one cannot be shown against
    /// another. Only `.removed` carried an id, which meant a late refusal for A silently
    /// overwrote a success for B with an unattributed message.
    @MainActor
    func testEveryOutcomeCarriesTheKildItIsAbout() async {
        let api = FakeKildAPI(kilds: [kild("a"), kild("b")])
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)

        await store.dispose(kild("a"), force: false)
        XCTAssertEqual(store.lastDisposal?.kild, "a")

        api.failDelete = .engine("refused")
        await store.dispose(kild("b"), force: false)
        XCTAssertEqual(store.lastDisposal?.kild, "b", "a refusal names its kild too")

        api.failDelete = .outcomeUnknown(verb: "disposal")
        await store.dispose(kild("a"), force: false)
        XCTAssertEqual(store.lastDisposal?.kild, "a", "and so does an unknown outcome")
    }
}
