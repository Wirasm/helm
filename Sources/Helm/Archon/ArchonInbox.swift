import Foundation

struct ArchonInboxDismissal: Codable, Equatable, Sendable {
    let id: String
    let dismissedAt: Date
}

/// The finished runs the operator has cleared, per workspace.
///
/// **This is `ArchonDismissals` brought back, and the difference is the surface it sits under.**
/// PR #147 deleted that type on a sound argument: with finished runs collapsed into a count and
/// no footer saying how many were hidden, a dismissal filter was "a silent, unreversible
/// filter" against something presenting itself as a complete tally. An inbox makes no claim to
/// completeness — clearing an item *is* the interaction — so the same mechanism is honest here.
///
/// What is new is the age-out. A cap alone bounds the store but not its meaning: a dismissal
/// from four months ago is not a decision the operator still holds, it is a row that will never
/// be seen again anyway, and keeping it only makes the blob bigger.
struct ArchonInboxDismissals: Equatable, Sendable {
    static let key = "archonInboxDismissed"
    static let capacity = 400
    /// Two weeks. Long enough that clearing a run before a holiday still holds when you get
    /// back; short enough that the store is not a diary.
    static let maximumAge: TimeInterval = 14 * 24 * 60 * 60

    /// Newest last, which is what makes `suffix(capacity)` the *keep* rather than the drop.
    ///
    /// Keyed by `WorkspacePath.value` rather than `WorkspacePath` itself: a `Dictionary` only
    /// encodes as a JSON object when its key is `String` (or `Int`) — a custom `Codable` key
    /// type serializes as a flat array instead, which would silently change the shape of
    /// `archonInboxDismissed` and strand every dismissal already on disk.
    private var byWorkspace: [String: [ArchonInboxDismissal]] = [:]

    init() {}

    static func load(from defaults: UserDefaults) -> ArchonInboxDismissals {
        guard let raw = defaults.string(forKey: key),
            let decoded = try? JSONDecoder().decode(
                [String: [ArchonInboxDismissal]].self, from: Data(raw.utf8))
        else { return ArchonInboxDismissals() }
        var dismissals = ArchonInboxDismissals()
        dismissals.byWorkspace = decoded
        return dismissals
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(byWorkspace) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    // MARK: - Reading

    func contains(_ runID: String, in workspacePath: WorkspacePath) -> Bool {
        byWorkspace[workspacePath.value]?.contains { $0.id == runID } ?? false
    }

    func total(in workspacePath: WorkspacePath) -> Int {
        byWorkspace[workspacePath.value]?.count ?? 0
    }

    // MARK: - Writing

    /// `now` is a parameter rather than a `Date()` inside, so the age-out has a test that does
    /// not depend on the wall clock.
    mutating func dismiss(_ runID: String, in workspacePath: WorkspacePath, now: Date) {
        var kept = (byWorkspace[workspacePath.value] ?? []).filter { $0.id != runID }
        kept.append(ArchonInboxDismissal(id: runID, dismissedAt: now))
        byWorkspace[workspacePath.value] = Array(kept.suffix(Self.capacity))
    }

    /// Age-out first, then the cap. A workspace left with nothing is dropped entirely rather
    /// than kept as an empty array, so the blob does not grow one key per workspace ever opened.
    mutating func prune(now: Date) {
        for (workspace, entries) in byWorkspace {
            let fresh = entries.filter {
                now.timeIntervalSince($0.dismissedAt) < Self.maximumAge
            }
            byWorkspace[workspace] = fresh.isEmpty ? nil : Array(fresh.suffix(Self.capacity))
        }
    }
}
