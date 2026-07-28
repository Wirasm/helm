import Foundation

@testable import Helm

/// One configurable `KildAPI` for the whole suite.
///
/// There were nine near-identical conformances across five test files, each spelling out
/// all thirteen methods to vary one of them. Adding `force:` to `delete` broke all nine at
/// once — which is the useful signal: the cost of a protocol change was being paid nine
/// times, and the ninth copy is where a subtly different stub eventually hides a bug.
///
/// Configure what a test cares about and ignore the rest. Failures are opt-in per call, so
/// "this route is down" is one line rather than a bespoke type.
final class FakeKildAPI: KildAPI, @unchecked Sendable {
    /// Named for the poll each feeds, so a test reads as the cadence it is exercising.
    var identities: [Kild] = []
    var status: [Kild] = []
    var archived: [ArchivedKild] = []
    var messageLog: [Message] = []
    var transcriptResult = AgentTranscript(entries: [], total: 0)
    var personaList: [String] = []
    var bootId = "boot-1"
    var landReport = LandFixture.landable()

    /// Routes that should throw. Named by the store-level poll they feed, so a test reads
    /// as "the status route is down" rather than as a type name.
    var failing: Set<Cockpit.Poll> = []
    /// Routes that should throw regardless of poll grouping.
    var failTranscript: KildAPIError?
    var failDelete: KildAPIError?

    /// Calls recorded, for tests that assert what was requested rather than what came back.
    private(set) var deleted: [(id: Kild.ID, force: Bool)] = []
    private(set) var sent: [(to: [String], text: String, kild: Kild.ID)] = []
    private(set) var stopped: [Kild.ID] = []

    init(kilds: [Kild] = [], status: [Kild]? = nil, archive: [ArchivedKild] = []) {
        self.identities = kilds
        self.status = status ?? kilds
        self.archived = archive
    }

    /// How many times each read was called — for tests asserting cadence rather than data.
    private(set) var callCounts: [Cockpit.Poll: Int] = [:]
    private func record(_ poll: Cockpit.Poll) { callCounts[poll, default: 0] += 1 }
    var kildsCalls: Int { callCounts[.identities] ?? 0 }
    var statusCalls: Int { callCounts[.status] ?? 0 }
    var archiveCalls: Int { callCounts[.archive] ?? 0 }
    var healthCalls: Int { callCounts[.health] ?? 0 }

    /// Per-route errors, for tests that name the failing route directly rather than by poll.
    /// Same mechanism as `failing`, spelled the way the older tests already read.
    var identitiesError: KildAPIError? { didSet { sync(.identities, identitiesError) } }
    var statusError: KildAPIError? { didSet { sync(.status, statusError) } }
    var archiveError: KildAPIError? { didSet { sync(.archive, archiveError) } }
    var healthError: KildAPIError? { didSet { sync(.health, healthError) } }
    /// Explicit health payload, when a test needs a specific bootId rather than the default.
    var healthResponse: Health?

    private func sync(_ poll: Cockpit.Poll, _ error: KildAPIError?) {
        if error == nil { failing.remove(poll) } else { failing.insert(poll) }
    }

    private func thrown(_ poll: Cockpit.Poll) -> KildAPIError {
        switch poll {
        case .identities: identitiesError ?? .engine("identities is down")
        case .status: statusError ?? .engine("status is down")
        case .archive: archiveError ?? .engine("archive is down")
        case .health: healthError ?? .engine("health is down")
        }
    }

    private func check(_ poll: Cockpit.Poll) throws {
        if failing.contains(poll) { throw thrown(poll) }
    }

    // MARK: - Reads

    func health() async throws -> Health {
        record(.health)
        try check(.health)
        return healthResponse ?? Health(ok: true, bootId: bootId)
    }

    func kilds() async throws -> [Kild] {
        record(.identities)
        try check(.identities)
        return identities
    }

    func kildsStatus() async throws -> [Kild] {
        record(.status)
        try check(.status)
        return status
    }

    func archive() async throws -> [ArchivedKild] {
        record(.archive)
        try check(.archive)
        return archived
    }

    func messages(in kild: Kild.ID, since seq: Int?) async throws -> [Message] {
        guard let seq else { return messageLog }
        return messageLog.filter { $0.seq > seq }
    }

    func transcript(of handle: String, in kild: Kild.ID) async throws -> AgentTranscript {
        if let failTranscript { throw failTranscript }
        return transcriptResult
    }

    func personas() async throws -> [String] { personaList }

    func landDryRun(_ kild: Kild.ID) async throws -> LandReport { landReport }

    // MARK: - Writes

    func send(to recipients: [String], text: String, in kild: Kild.ID) async throws {
        sent.append((to: recipients, text: text, kild: kild))
    }

    func land(_ kild: Kild.ID) async throws -> LandReport { landReport }

    @discardableResult
    func delete(_ kild: Kild.ID, force: Bool) async throws -> DisposalReport {
        deleted.append((id: kild, force: force))
        if let failDelete { throw failDelete }
        return DisposalReport(
            id: kild, worktree: kild, branch: "kild/\(kild)", branchKept: true,
            removed: "/worktrees/\(kild)", discarded: [], discardedError: nil,
            forced: force, message: "Removed worktree '\(kild)'. Branch kept.")
    }

    func stop(_ kild: Kild.ID) async throws { stopped.append(kild) }

    func stopAgent(_ handle: String, in kild: Kild.ID) async throws {}
}
