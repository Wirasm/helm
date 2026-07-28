import Foundation

/// Removing a kild's worktree — the verb that reclaims disk.
///
/// This exists because the observe column can now *see* 116 abandoned trees and could not
/// act on any of them. Measured on this machine: **5.4 GB across 116 worktrees**, two of
/// them 1.8 GB each, and `prune` reclaims none of it — prune only removes trees whose branch
/// already merged, so abandoned work is structurally permanent. Showing them without a way
/// to dispose of them is half a feature.
///
/// The engine guards the destructive part; helm's job is to report what it said without
/// softening it.

/// What `DELETE /api/kilds/:id` returns when it removed the tree.
struct DisposalReport: Codable, Sendable, Equatable {
    let id: String
    let worktree: String
    /// The branch, which **survives**. Removing a worktree frees disk; it never deletes
    /// work, and saying so is the difference between an action a person will take and one
    /// they will avoid.
    let branch: String
    let branchKept: Bool
    /// The directory that is gone.
    let removed: String
    /// Paths that were discarded with the tree — uncommitted changes, untracked files.
    ///
    /// **Read `discardedFiles`, not this.** An empty array here means one of two opposite
    /// things depending on `discardedError`, and the engine says so in its own source: *"an
    /// empty `discarded` beside this is 'unknown', not 'nothing' — the one distinction a
    /// disposal report must never lose."*
    let discarded: [String]
    /// Set only when git could not produce the list.
    var discardedError: String?
    /// True when the caller passed `force=true` and the engine went past unlanded commits.
    let forced: Bool
    /// The engine's own sentence. Rendered verbatim.
    let message: String

    /// What was discarded, or `nil` when the engine could not tell.
    ///
    /// The three states the flat fields cannot express on their own:
    /// `nil` — unknown, git failed;
    /// `[]` — measured, nothing was discarded;
    /// non-empty — these specific paths are gone.
    ///
    /// Rendering `[]` as "nothing was lost" when the truth is "we could not check" would be
    /// the most reassuring possible message about an irreversible action.
    var discardedFiles: [String]? {
        discardedError == nil ? discarded : nil
    }
}

/// What `DELETE /api/kilds/:id` returns when it refused.
///
/// A refusal is the normal, useful case: the guard is *authored commits*, so the engine
/// declines to discard work nobody has landed. Its `tip` usually names the way forward.
struct DisposalRefusal: Codable, Sendable, Equatable {
    let error: String
    /// `no_worktree`, `not_found`, `rejected`, or an assessment code.
    var code: String?
    var branch: String?
    /// Unlanded commits found on the branch — why it refused, and how much is at stake.
    var commits: Int?
    /// The engine's suggested next step, when it has one.
    var tip: String?

    /// A kild that ran in the main checkout has no worktree to remove. Not a failure —
    /// there is simply nothing to dispose of, and offering the action at all was the error.
    var isNothingToDispose: Bool { code == "no_worktree" }

    /// Refused because the branch carries work nobody landed. This is the guard doing its
    /// job, and the only refusal `force` can override.
    var isUnlandedWork: Bool { (commits ?? 0) > 0 }
}

/// Whether helm should offer disposal for a kild at all.
enum Disposal {
    /// A kild is disposable when it has a worktree to remove.
    ///
    /// A kild that ran in the main checkout has none — its `cwd` *is* the repo — and
    /// offering the action there would produce a refusal the operator could have been
    /// spared. Orphans are the main case: they exist only as trees, which is precisely why
    /// they are the ones taking up the disk.
    static func isDisposable(_ kild: Kild) -> Bool {
        kild.worktree != nil
    }

    /// How to describe the action before it is taken.
    ///
    /// Names the branch survival explicitly. The engine keeps `kild/<worktree>` on every
    /// path including `force`, so the honest framing is "reclaim the tree", not "delete the
    /// kild" — and an operator who believes they are deleting work will not press it.
    static func confirmation(for kild: Kild) -> String {
        let name = kild.worktree ?? kild.name
        return """
            Remove the worktree for “\(name)”?

            This frees its disk. The branch kild/\(name) is kept, so no commits are lost. \
            Uncommitted changes in the tree are discarded.
            """
    }

    /// What to show after a successful disposal.
    ///
    /// Prefers the engine's sentence, and appends the discarded detail only when it is
    /// genuinely known.
    static func summary(of report: DisposalReport) -> String {
        guard let files = report.discardedFiles else {
            return report.message  // already carries the "could not determine" clause
        }
        guard !files.isEmpty else { return report.message }
        return report.message + " Discarded: " + files.prefix(5).joined(separator: ", ")
            + (files.count > 5 ? " and \(files.count - 5) more." : ".")
    }
}
