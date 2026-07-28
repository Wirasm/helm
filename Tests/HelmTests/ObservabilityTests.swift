import Combine
import XCTest

@testable import Helm

/// That engine state actually reaches the view layer.
///
/// **Nothing caught the bug this guards.** `KildStore` held `Cockpit` as a plain `let`, and
/// Combine synthesises a publisher on the type where a property is *declared* — so mutating
/// `cockpit.kilds` fired `Cockpit.objectWillChange` and nothing forwarded it. No view
/// observes `Cockpit` directly, so the frame rendered once against an empty engine and
/// froze. Every poll ran, decoded correctly, and updated state that nothing redrew.
///
/// The whole suite was green. A 25-second run against the live engine reported zero decode
/// failures — true, and measuring the wrong end of the pipe. The data path was perfect; the
/// path from data to screen did not exist.
///
/// These tests assert the seam that no other test touches: **a change inside `Cockpit` must
/// produce a change notification on `KildStore`**, because that notification is the only
/// thing that makes SwiftUI re-render.
final class ObservabilityTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    /// Count notifications on `KildStore` while mutating only `Cockpit`.
    @MainActor
    private func notifications(
        from store: KildStore, while body: @MainActor () async -> Void
    ) async -> Int {
        var count = 0
        store.objectWillChange
            .sink { _ in count += 1 }
            .store(in: &cancellables)
        await body()
        return count
    }

    // MARK: - The forwarding itself

    /// The exact regression: kilds arriving must notify the store.
    @MainActor
    func testKildsArrivingNotifiesTheStore() async {
        let store = KildStore(api: OneKildAPI(), defaults: scratch(), launchKild: nil)
        let count = await notifications(from: store) { await store.loadIdentities() }

        XCTAssertGreaterThan(
            count, 0,
            "without a forwarded notification the sidebar never redraws, however correct the data")
        XCTAssertEqual(store.cockpit.kilds.count, 1, "and the data did arrive")
    }

    /// The costly half too — git and cost land on `Cockpit`, not on the store.
    @MainActor
    func testStatusArrivingNotifiesTheStore() async {
        let store = KildStore(api: OneKildAPI(), defaults: scratch(), launchKild: nil)
        await store.loadIdentities()
        let count = await notifications(from: store) { await store.loadStatus() }
        XCTAssertGreaterThan(count, 0)
    }

    @MainActor
    func testArchiveArrivingNotifiesTheStore() async {
        let store = KildStore(api: OneKildAPI(), defaults: scratch(), launchKild: nil)
        let count = await notifications(from: store) { await store.loadArchive() }
        XCTAssertGreaterThan(count, 0)
    }

    /// `errors` is a Dictionary rather than a scalar — worth asserting separately, because
    /// a failing poll that never notifies leaves the UI showing stale data with no
    /// indication anything is wrong, which is the failure `errors` exists to prevent.
    @MainActor
    func testAFailingPollAlsoNotifies() async {
        let store = KildStore(api: BrokenAPI(), defaults: scratch(), launchKild: nil)
        let count = await notifications(from: store) { await store.loadIdentities() }

        XCTAssertGreaterThan(count, 0, "the error must be able to reach the screen too")
        XCTAssertNotNil(store.cockpit.errors[.identities])
    }

    /// A boot change discards everything — the most destructive state transition there is,
    /// and therefore the one that most needs to redraw.
    ///
    /// The archive is what makes the reset observable. `loadIdentities()` runs `checkBoot()`
    /// — which clears — and then `refreshIdentities()`, which immediately refetches, so
    /// `kilds` is correctly non-empty again a moment later. Asserting on `kilds` would be
    /// asserting that the store fails to recover.
    @MainActor
    func testABootChangeNotifiesAndDiscardsStateFromTheDeadEngine() async {
        let api = ReBootingAPI()
        let store = KildStore(api: api, defaults: scratch(), launchKild: nil)
        await store.loadIdentities()
        await store.loadArchive()
        XCTAssertFalse(store.cockpit.archive.isEmpty, "precondition: state from boot-1")

        api.bootId = "boot-2"
        let count = await notifications(from: store) { await store.loadIdentities() }

        XCTAssertGreaterThan(count, 0, "the reset itself must reach the screen")
        XCTAssertTrue(
            store.cockpit.archive.isEmpty,
            "an id from the previous process can collide with nothing — or with something different")
        XCTAssertEqual(store.cockpit.bootId, "boot-2")
    }

    // MARK: - No retain cycle

    /// The sink captures `self` weakly and is stored on `self`. If that were a strong
    /// capture the store would never deallocate, and every workspace switch would leak one
    /// alongside its live polling.
    @MainActor
    func testTheStoreDeallocatesDespiteHoldingItsOwnSubscription() async {
        weak var weakStore: KildStore?
        do {
            let store = KildStore(api: OneKildAPI(), defaults: scratch(), launchKild: nil)
            await store.loadIdentities()
            weakStore = store
            XCTAssertNotNil(weakStore)
        }
        XCTAssertNil(weakStore, "a strong capture in the objectWillChange sink would pin it")
    }

    // MARK: - Helpers

    private func scratch() -> UserDefaults {
        let suite = "helm.observability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private struct OneKildAPI: KildAPI {
        func health() async throws -> Health { Health(ok: true, bootId: "boot-1") }
        func kilds() async throws -> [Kild] {
            [Kild(id: "k", name: "k", cwd: "/repo", agents: [])]
        }
        func kildsStatus() async throws -> [Kild] {
            [Kild(id: "k", name: "k", cwd: "/repo", agents: [], git: GitFixture.measured(ahead: 2))]
        }
        func archive() async throws -> [ArchivedKild] {
            [ArchivedKild(id: "a", name: "a", agents: [], cwd: "/repo")]
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

    private struct BrokenAPI: KildAPI {
        func health() async throws -> Health { throw KildAPIError.engine("down") }
        func kilds() async throws -> [Kild] { throw KildAPIError.engine("down") }
        func kildsStatus() async throws -> [Kild] { throw KildAPIError.engine("down") }
        func archive() async throws -> [ArchivedKild] { throw KildAPIError.engine("down") }
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

    private final class ReBootingAPI: KildAPI, @unchecked Sendable {
        var bootId = "boot-1"
        func health() async throws -> Health { Health(ok: true, bootId: bootId) }
        func kilds() async throws -> [Kild] {
            [Kild(id: "k", name: "k", cwd: "/repo", agents: [])]
        }
        func kildsStatus() async throws -> [Kild] { [] }
        func archive() async throws -> [ArchivedKild] {
            [ArchivedKild(id: "a", name: "a", agents: [], cwd: "/repo")]
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
