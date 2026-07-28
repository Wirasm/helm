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

        // Nothing to land is a refusal, not a no-op: it almost always means the wrong kild
        // is selected. `commits` empty is the engine's way of saying it — there is no
        // ahead/behind on this route.
        let count = report.commits.count
        checks.append(
            Check(
                id: "position",
                text: count == 0
                    ? "nothing to land — no commits on \(report.branch ?? "this branch")"
                    : "\(count) commit\(count == 1 ? "" : "s") to land into \(report.base)",
                verdict: count == 0 ? .fail : .pass,
                derived: false))

        // The engine's own merge verdict. `wouldMerge` covers both halves: would it apply
        // (dry run), did it apply (execute).
        checks.append(
            Check(
                id: "merge",
                text: report.wouldMerge
                    ? "merges into \(report.base) cleanly"
                    : "will not merge into \(report.base)",
                verdict: report.wouldMerge ? .pass : .fail,
                derived: false))

        // The engine's collision preview — this branch against its base. NOT derived.
        if !report.collides.isEmpty {
            let n = report.collides.count
            checks.append(
                Check(
                    id: "conflicts",
                    text: "\(n) path\(n == 1 ? "" : "s") conflict with \(report.base)",
                    verdict: .fail,
                    derived: false))
        }

        // Agents still working. Landing under one races its next commit.
        let running = runningAgents.filter { !$0.isStopped && !$0.isIdle }
        if !running.isEmpty {
            checks.append(
                Check(
                    id: "agents",
                    text: "\(running.count) agent\(running.count == 1 ? "" : "s") still running",
                    verdict: .fail,
                    derived: false))
        }

        // A failed git probe is not a clean tree. On failure the engine returns safe
        // defaults that read exactly like an up-to-date, unmodified repository, so without
        // this the gate would show its most reassuring face over a measurement that never
        // happened.
        if let git = kild.git, !git.isTrustworthy {
            checks.append(
                Check(
                    id: "measurement",
                    text: "could not read git state — \(git.error ?? "unknown failure")",
                    verdict: .fail,
                    derived: false))
        }

        // DERIVED — the cross-kild collision, which no single kild can know and no route
        // reports. Distinct from `report.collides` above, which is this branch vs its base.
        if collisions.isEmpty {
            checks.append(
                Check(
                    id: "collisions", text: "no collisions with live kilds", verdict: .pass,
                    derived: true))
        } else {
            let names = collisions.map(\.otherName).joined(separator: ", ")
            let unique = Set(collisions.flatMap(\.files)).count
            checks.append(
                Check(
                    id: "collisions",
                    text: "collides with \(names) · \(unique) file\(unique == 1 ? "" : "s")",
                    verdict: .fail,
                    derived: true))
        }

        if !report.files.isEmpty {
            let n = report.files.count
            checks.append(
                Check(
                    id: "diffstat", text: "\(n) file\(n == 1 ? "" : "s") changed",
                    verdict: .info, derived: false))
        }

        // The engine's own words always win. It knows things helm never asked about, and
        // re-deriving a worse version of a message we already have is strictly less useful.
        if let error = report.error, !error.isEmpty {
            checks.append(Check(id: "engine", text: error, verdict: .fail, derived: false))
        }

        return LandGate(
            kild: kild.id,
            kildName: kild.name,
            base: report.base,
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
