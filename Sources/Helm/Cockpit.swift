import Foundation

/// The observed state of the engine — the one place the UI reads from.
///
/// Everything here is either a value the engine sent or a derivation named as such. The
/// cockpit holds no opinions the engine could contradict: no optimistic writes, no local
/// mutation of a kild after an action, no cached "what it probably looks like now". An
/// action is sent, and the next poll says what happened. That is slower to feel, and it is
/// the only version that cannot drift.
@MainActor
final class Cockpit: ObservableObject {
    /// Live kilds — identity merged with whatever status has arrived for them.
    @Published private(set) var kilds: [Kild] = []
    /// Stopped kilds. Carries no log; fetch messages per kild when one is opened.
    @Published private(set) var archive: [ArchivedKild] = []
    /// The engine's boot identity. A change means everything held here is from an engine
    /// that no longer exists.
    @Published private(set) var bootId: String?
    /// The last failure, in the engine's own words. Held rather than thrown so the UI can
    /// show that the picture is stale instead of silently rendering old data as current.
    @Published private(set) var lastError: String?

    private let api: KildAPI

    init(api: KildAPI) {
        self.api = api
    }

    // MARK: - Derivations

    /// How many agents are waiting on you, across every kild. Zero renders as absence.
    var waitingCount: Int { Attention.waitingCount(in: kilds) }

    /// Which kilds are working on the same files as which others. Derived client-side;
    /// label it as derived wherever it is shown.
    var collisions: [Kild.ID: [Collision]] { Attention.collisions(among: kilds) }

    /// Live kilds and orphans, each sorted for a stable column.
    var groups: [KildGroup: [Kild]] { Attention.grouped(kilds) }

    // MARK: - Refresh

    /// The cheap half: identity, agents, `idle`, `orphan`. Safe to poll often — no git,
    /// no subprocesses.
    func refreshIdentities() async {
        do {
            let fetched = try await api.kilds()
            kilds = Self.merge(identities: fetched, into: kilds)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The costly half: one git invocation per kild. Belongs on a slower cadence.
    func refreshStatus() async {
        do {
            let fetched = try await api.kildsStatus()
            kilds = Self.apply(status: fetched, to: kilds)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshArchive() async {
        do {
            archive = try await api.archive().sorted(by: Self.newestFirst)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Check the engine's identity, and drop everything if it restarted.
    ///
    /// State from a previous boot is not merely stale, it is about objects that may no
    /// longer exist — a kild id from the old process can collide with nothing or, worse,
    /// with something different. Clearing is the only honest response.
    func checkBoot() async {
        do {
            let health = try await api.health()
            if let known = bootId, known != health.bootId {
                kilds = []
                archive = []
            }
            bootId = health.bootId
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Merging the split listing

    /// Fold a fresh identity listing into what we hold, preserving status already fetched.
    ///
    /// The two halves arrive on different cadences, so each must keep what the other owns.
    /// **Identity is authoritative for existence and for agents**: a kild absent from this
    /// listing is gone, and its status goes with it. **Status is authoritative for git and
    /// cost**, so those survive an identity refresh that does not carry them — otherwise
    /// every cheap poll would blank the git column until the next costly one, and the UI
    /// would flicker between "3 ahead" and nothing at the polling ratio.
    static func merge(identities: [Kild], into existing: [Kild]) -> [Kild] {
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return identities.map { fresh in
            guard let old = previous[fresh.id] else { return fresh }
            var merged = fresh
            merged.git = old.git
            merged.totals = old.totals
            merged.landedSha = old.landedSha
            merged.landed = old.landed
            return merged
        }
    }

    /// Fold a status listing into what we hold.
    ///
    /// Status carries identity too, but this deliberately keeps the identity we already
    /// have: the cheap listing runs more often, so its agents and `idle` are the fresher
    /// truth. Taking status wholesale would roll attention back to whenever the slow poll
    /// started — an agent that went idle in between would stop asking for you.
    ///
    /// Status for a kild we do not hold is dropped rather than added. It means the kild
    /// vanished between the two calls, and resurrecting it from the slower half would show
    /// a kild that no longer exists.
    static func apply(status: [Kild], to existing: [Kild]) -> [Kild] {
        let byID = Dictionary(status.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return existing.map { held in
            guard let fresh = byID[held.id] else { return held }
            var merged = held
            merged.git = fresh.git
            merged.totals = fresh.totals
            merged.landedSha = fresh.landedSha
            merged.landed = fresh.landed
            return merged
        }
    }

    /// Newest first, with clockless archives last.
    ///
    /// `endedAt` is absent on archives written before the field existed, and there is no
    /// fallback by design — the log that once carried a timestamp is no longer in the
    /// listing, and inventing one would present a guess as a fact. They sort to the end,
    /// which is honest: we do not know when they ended, so we do not claim a position.
    static func newestFirst(_ lhs: ArchivedKild, _ rhs: ArchivedKild) -> Bool {
        switch (lhs.endedAt, rhs.endedAt) {
        case let (l?, r?): l > r
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
