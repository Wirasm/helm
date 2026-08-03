import Foundation

/// What Archon lets you do TO a run, and the complete list of it.
///
/// **Checked against Archon's own dispatch rather than assumed.** `packages/cli/src/cli.ts`
/// has exactly four run-scoped verbs — `abandon`, `approve`, `reject`, `resume` — and there
/// is no delete, archive or purge among them. Everything a rail can offer on a run is here or
/// is helm's own invention, and the two must never be dressed the same (see
/// `ArchonDismissals`).
///
/// `resume` is deliberately absent from this enum even though it is one of the four, because
/// it is not the same *shape* of call: see `ArchonClient.resume(_:)`.
enum ArchonRunAction: Equatable, Sendable {
    /// Ends the run. Archon marks it `cancelled` and reclaims its container.
    case abandon
    /// Passes an approval gate. Records the decision; **does not restart the run** — see the
    /// note on `resumesTheRun`.
    case approve(comment: String?)
    /// Fails an approval gate. Either cancels the run or hands it to an `on_reject` rework
    /// pass, which Archon reports in the acknowledgement rather than deciding here.
    case reject(reason: String?)

    /// What the operator sees, and what Archon calls it. The same word on purpose: a control
    /// named for something other than the CLI verb it runs is a translation nobody asked for.
    var verb: String {
        switch self {
        case .abandon: "abandon"
        case .approve: "approve"
        case .reject: "reject"
        }
    }

    /// **Every one of these needs a follow-up run to actually continue.** `--json` mode on
    /// `approve` and `reject` records the decision and returns *without* executing, because
    /// executing streams workflow output to stdout and would corrupt the one-line JSON
    /// contract. Archon says so in the payload (`resumable`), and the CLI's own interactive
    /// form resumes immediately afterwards — which is why helm does too.
    ///
    /// `abandon` is terminal and never resumes.
    var mayResume: Bool {
        switch self {
        case .abandon: false
        case .approve, .reject: true
        }
    }

    func arguments(for runID: String) -> [String] {
        switch self {
        case .abandon:
            ["workflow", "abandon", runID, "--json"]
        case let .approve(comment):
            ["workflow", "approve", runID, "--json"] + (comment.map { ["--comment", $0] } ?? [])
        case let .reject(reason):
            ["workflow", "reject", runID, "--json"] + (reason.map { ["--reason", $0] } ?? [])
        }
    }
}

/// One line of JSON from `abandon`, `approve` or `reject`.
///
/// **`ok` is the whole contract, and the exit status is not.** In `--json` mode these
/// commands catch their own failures and print `{"ok": false, …, "error": "…"}` — then return
/// zero. A caller that trusts the exit status reports "abandoned" for a run that was never
/// found, which is the failure this type exists to make impossible.
///
/// Every field but `ok`, `runId` and `action` is optional because the three verbs answer with
/// three different subsets: `abandon` sends `status`, `approve` sends `type` and `resumable`,
/// `reject` sends `cancelled`, `maxAttemptsReached` and `resumable`.
struct ArchonActionAcknowledgement: Codable, Equatable, Sendable {
    let ok: Bool
    let runId: String
    let action: String
    let workflowName: String?
    /// `abandon` only, and always `cancelled` when it succeeds.
    let status: String?
    /// `reject` only. False means the run went to an `on_reject` rework rather than ending.
    let cancelled: Bool?
    let maxAttemptsReached: Bool?
    /// `approve` and `reject`. True means Archon parked a run that now needs driving.
    let resumable: Bool?
    /// Present exactly when `ok` is false.
    let error: String?

    /// Whether this acknowledgement leaves a run that helm should now resume.
    var leavesRunResumable: Bool { ok && resumable == true }
}
