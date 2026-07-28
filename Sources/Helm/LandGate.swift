import Foundation

/// What the land gate shows, as a value.
///
/// Separate from the view so the rule that actually matters — *when is landing allowed* —
/// can be tested without a window. Landing is the one action in the model that mutates a
/// branch you care about, so its precondition should be checkable in isolation rather than
/// inferred from whether a button happens to look grey.
struct LandGate: Equatable {
    /// One line in the gate. Each states a fact and whether that fact blocks the land.
    struct Check: Equatable, Identifiable {
        enum Verdict: Equatable {
            /// Satisfied — does not block.
            case pass
            /// Blocks the land.
            case fail
            /// Context, neither passing nor failing (a file count, a diffstat).
            case info
        }

        let id: String
        let text: String
        let verdict: Verdict
        /// True when helm computed this rather than the engine reporting it.
        ///
        /// Marking matters more here than anywhere else in the app: this is the most
        /// reassuring line on the most consequential screen, and a reader has no other way
        /// to tell it from server truth. If the engine ever reports collisions itself, the
        /// tag comes off and nothing else changes.
        let derived: Bool

        var blocks: Bool { verdict == .fail }
    }

    let kild: Kild.ID
    let kildName: String
    let base: String
    let checks: [Check]
    /// Kilds this one collides with — rendered as links, because the fix is over there.
    let collidesWith: [Collision]

    /// Landing is allowed only when nothing blocks.
    ///
    /// The button disables rather than warns. A warning that can be clicked through is a
    /// warning that will be clicked through, and this is the one action that rewrites a
    /// branch somebody else may be measuring against.
    var canLand: Bool { !checks.contains(\.blocks) }

    /// Build the gate from the engine's dry run plus helm's own collision derivation.
    ///
    /// The two sources are kept visibly distinct: every check from `report` is server
    /// truth, and the single check built from `collisions` carries `derived: true`. That is
    /// the whole reason this takes two parameters instead of one enriched object.
    static func make(
        kild: Kild,
        report: LandReport,
        collisions: [Collision],
        runningAgents: [Agent]
    ) -> LandGate {
        var checks: [Check] = []

        // Position relative to base. "Nothing to land" is a refusal, not a no-op: it almost
        // always means the wrong kild is selected.
        let ahead = report.ahead ?? 0
        let behind = report.behind ?? 0
        checks.append(
            Check(
                id: "position",
                text: ahead == 0
                    ? "nothing to land — 0 commits ahead of \(kild.base ?? "base")"
                    : "\(ahead) commit\(ahead == 1 ? "" : "s") ahead, \(behind) behind",
                verdict: ahead == 0 ? .fail : .pass,
                derived: false))

        // A dirty tree is reported but does NOT block: on the machine that measured this,
        // 27 of 27 agent worktrees were dirty from provisioning litter written before any
        // agent ran. Blocking on dirt would refuse every real kild, which is exactly how
        // 116 worktrees became permanently unreclaimable.
        if report.dirty == true {
            checks.append(
                Check(
                    id: "tree",
                    text: "working tree has uncommitted changes",
                    verdict: .info,
                    derived: false))
        } else {
            checks.append(
                Check(id: "tree", text: "working tree clean", verdict: .pass, derived: false))
        }

        let conflicts = report.conflictsWithBase == true
        checks.append(
            Check(
                id: "merge",
                text: conflicts
                    ? "conflicts with \(kild.base ?? "base")" : "merges without conflict",
                verdict: conflicts ? .fail : .pass,
                derived: false))

        // Agents still working. Landing under a running agent races its next commit.
        let running = runningAgents.filter { !$0.isStopped && !$0.isIdle }
        if !running.isEmpty {
            checks.append(
                Check(
                    id: "agents",
                    text: "\(running.count) agent\(running.count == 1 ? "" : "s") still running",
                    verdict: .fail,
                    derived: false))
        }

        // DERIVED — the only line here helm computed rather than read.
        if collisions.isEmpty {
            checks.append(
                Check(
                    id: "collisions", text: "no collisions with live kilds", verdict: .pass,
                    derived: true))
        } else {
            let names = collisions.map(\.otherName).joined(separator: ", ")
            let files = collisions.flatMap(\.files)
            let unique = Set(files).count
            checks.append(
                Check(
                    id: "collisions",
                    text:
                        "collides with \(names) · \(unique) file\(unique == 1 ? "" : "s")",
                    verdict: .fail,
                    derived: true))
        }

        if let files = report.files, let commits = report.commits {
            checks.append(
                Check(
                    id: "diffstat",
                    text: "\(commits) commit\(commits == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")",
                    verdict: .info,
                    derived: false))
        }

        // The engine's own refusal always wins. It knows things helm did not ask about, and
        // its wording is the whole answer — re-deriving a worse version of a message we
        // already have would be strictly less useful.
        if let error = report.error, !error.isEmpty {
            checks.append(
                Check(id: "engine", text: error, verdict: .fail, derived: false))
        }

        return LandGate(
            kild: kild.id,
            kildName: kild.name,
            base: kild.base ?? "base",
            checks: checks,
            collidesWith: collisions)
    }
}

extension Array {
    /// `contains` over a key path, for reading as prose at the call site.
    fileprivate func contains(_ path: KeyPath<Element, Bool>) -> Bool {
        contains { $0[keyPath: path] }
    }
}
