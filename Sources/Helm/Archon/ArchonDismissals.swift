import Foundation

/// One run helm has been told to stop showing, and the status it had when that was said.
///
/// The status rides along because the rail's collapsed lines are **counts Archon computes over
/// the whole project**, not over the twenty rows it returns. Subtracting a dismissal from the
/// right bucket is the only way "dismiss all 128 completed" can make that line go away without
/// helm inventing a number of its own.
struct ArchonDismissal: Codable, Equatable, Sendable {
    let id: String
    let status: String
}

/// helm's own record of runs it has been told to stop showing — **and nothing else**.
///
/// **This is not deletion and must never be dressed as it.** Archon has no delete, archive or
/// purge for a run: its run-scoped verbs are `abandon`, `approve`, `reject` and `resume`, and
/// the only removal anywhere in the CLI is `archon workflow cleanup <days>`, which is
/// age-based, global to the machine, and answers a different question entirely. Reaching into
/// Archon's SQLite to delete a row is forbidden by #40's first acceptance line, and owning
/// both repos makes that more tempting rather than less wrong.
///
/// So a dismissed run is still in `archon workflow runs`, still in `workflow get`, and still
/// counted by every other Archon surface. It has stopped appearing in **this rail**, in **this
/// workspace**, on **this machine**. A control that promised more than that would be a lie the
/// operator finds a week later.
///
/// **Deliberately forgettable.** Bounded at `capacity` per workspace, newest kept, so the
/// stored set cannot grow without limit across a year of runs. A dismissed run reappearing
/// after that is not a bug — it is the property, and it is why nothing here is called
/// "deleted".
struct ArchonDismissals: Equatable, Sendable {
    static let key = "archonDismissedRuns"
    /// Enough to swallow a project's whole visible history several times over — the captured
    /// fixture's project had 128 runs — and small enough that the blob stays a few kilobytes.
    static let capacity = 400

    /// Newest last, which is what makes `suffix(capacity)` the *keep* rather than the drop.
    private var byWorkspace: [String: [ArchonDismissal]] = [:]

    init() {}

    static func load(from defaults: UserDefaults) -> ArchonDismissals {
        guard let raw = defaults.string(forKey: key),
            let decoded = try? JSONDecoder().decode(
                [String: [ArchonDismissal]].self, from: Data(raw.utf8))
        else { return ArchonDismissals() }
        var dismissals = ArchonDismissals()
        dismissals.byWorkspace = decoded
        return dismissals
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(byWorkspace) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    // MARK: - Reading

    func contains(_ runID: String, in workspacePath: String) -> Bool {
        byWorkspace[workspacePath]?.contains { $0.id == runID } ?? false
    }

    /// How many dismissals were recorded under this status — what the rail subtracts from
    /// Archon's count for it.
    func count(of status: String, in workspacePath: String) -> Int {
        byWorkspace[workspacePath]?.count { $0.status == status } ?? 0
    }

    func total(in workspacePath: String) -> Int {
        byWorkspace[workspacePath]?.count ?? 0
    }

    // MARK: - Writing

    /// Records dismissals, replacing any earlier entry for the same run so a run dismissed
    /// while it was `running` and again once `completed` is counted once, in the bucket it is
    /// in now.
    mutating func dismiss(_ dismissals: [ArchonDismissal], in workspacePath: String) {
        guard !dismissals.isEmpty else { return }
        let incoming = Set(dismissals.map(\.id))
        var kept = (byWorkspace[workspacePath] ?? []).filter { !incoming.contains($0.id) }
        kept.append(contentsOf: dismissals)
        byWorkspace[workspacePath] = Array(kept.suffix(Self.capacity))
    }

    /// The undo. There is one because dismissal is a view filter, and a filter with no way
    /// back is indistinguishable from the deletion this deliberately is not.
    mutating func restoreAll(in workspacePath: String) {
        byWorkspace[workspacePath] = nil
    }
}
