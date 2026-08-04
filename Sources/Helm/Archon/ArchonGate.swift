import Foundation

/// The gate a paused run is waiting at, read out of `metadata.approval`.
///
/// **A paused run is not automatically something you can act on, and this type is how helm
/// tells the difference.** Archon writes the whole approval context into the run's metadata
/// (`packages/core/src/db/workflows.ts`, `pauseWorkflowRun`), and it arrives untouched in
/// `workflow runs --json` — so the gate costs no extra call. Three of its fields decide
/// whether a control should exist at all:
///
/// - `resolved` is stamped by approve/reject **while the run stays `paused`** awaiting
///   auto-resume. A resolved gate is not waiting for you, and approving it a second time
///   throws *"was already approved and is awaiting resume"*.
/// - `type == .childWorkflow` means the pause belongs to a `workflow:` sub-run. Approving the
///   parent throws and tells you to approve the child by id instead.
/// - `captureResponse` means the comment **becomes the node's output** (`$nodeId.output`), so
///   an approve with nothing typed silently writes the literal string `Approved` into the run.
///
/// All three were read off `workflow-operations.ts` and `workflow-run.ts` rather than assumed,
/// which is the standing rule for this vocabulary.
struct ArchonGate: Equatable, Sendable {
    /// The stage holding the run — the parent's own node under `childWorkflow`.
    let nodeId: String
    /// **Archon's question to the human.** The one piece of a gate that is worth a subline:
    /// it says what is being asked, where the node id only says where.
    let message: String
    let type: Kind
    /// The paused sub-run to act on instead, when `type` is `childWorkflow`.
    let childRunId: String?
    /// True when the approval comment is stored as the node's output.
    let captureResponse: Bool
    /// `approved`, `rejected`, or nil while the gate is still waiting for a person.
    let resolved: String?

    /// Open, for the reason `ArchonNode.State` is open and `ArchonRun.status` is a raw string:
    /// this vocabulary lives in a repo with zero knowledge of helm and has grown twice already
    /// (`writeback` and `childWorkflow` are both newer than the first two).
    ///
    /// **Absent means `approval`.** Archon declares the field optional and a plain DAG approval
    /// node writes no `type` at all, so a missing key is a gate rather than an unknown.
    enum Kind: Equatable, Sendable {
        case approval, interactiveLoop, writeback, childWorkflow
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "approval": self = .approval
            case "interactive_loop": self = .interactiveLoop
            case "writeback": self = .writeback
            case "child_workflow": self = .childWorkflow
            default: self = .unknown(raw)
            }
        }

        var raw: String {
            switch self {
            case .approval: "approval"
            case .interactiveLoop: "interactive_loop"
            case .writeback: "writeback"
            case .childWorkflow: "child_workflow"
            case let .unknown(name): name
            }
        }
    }

    /// Whether this gate is waiting for **the operator**, here, now.
    ///
    /// The two exclusions are not caution — each is a call Archon answers by throwing, so a
    /// control offered against them is a control that cannot work.
    var isAwaitingDecision: Bool {
        guard resolved == nil else { return false }
        if case .childWorkflow = type { return false }
        return true
    }

    /// Why there are no verbs on a paused run, in the words the operator needs to act.
    ///
    /// nil when the gate *is* actionable. A sentence rather than a state name, because "this
    /// row has no buttons" is the observation and this is the answer to it.
    var blockedReason: String? {
        if case .childWorkflow = type {
            return childRunId.map {
                "Blocked on sub-run \(String($0.prefix(8))) — decide that one."
            }
                ?? "Blocked on a sub-run — decide that one."
        }
        switch resolved {
        case "approved": return "Approved — waiting for Archon to resume it."
        case "rejected": return "Rejected — waiting for Archon to resume it."
        case let other?: return "Already \(other) — waiting for Archon to resume it."
        case nil: return nil
        }
    }

    /// Whether a decision on this gate should collect text before it is sent.
    ///
    /// **Reject always does.** The reason is fed to the `on_reject` rework prompt, and a rework
    /// pass told only that it failed is the same defect as approving blind.
    ///
    /// **Approve does only when the text is load-bearing**, which Archon says outright:
    /// `captureResponse` makes the comment the node's output, and an `interactiveLoop` gate
    /// discriminates finalize-from-iterate on whether a comment was given at all
    /// (`loop_feedback_given`, Archon #2074). Everywhere else the comment lands in an audit
    /// event and nothing reads it, so demanding a sentence for it would be a click that buys
    /// nothing.
    func needsText(for decision: ArchonGateDecision) -> Bool {
        switch decision {
        case .reject: true
        case .approve:
            if captureResponse { true } else if case .interactiveLoop = type { true } else { false }
        }
    }
}

extension ArchonGate: Codable {
    /// **Lenient on purpose, and it is the same lesson twice already paid for.** A closed
    /// `ArchonNode.State` once failed a whole run's decode on one unrecognised word, and a
    /// decoder built from an imagined date format broke the feature against 514 green tests.
    /// Archon's own reader guards this blob for exactly this reason — `isApprovalContext`
    /// exists because stale runs carry a different metadata shape — so a gate helm cannot read
    /// must cost the gate and never the run.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        type = Kind(raw: try container.decodeIfPresent(String.self, forKey: .type) ?? "approval")
        childRunId = try container.decodeIfPresent(String.self, forKey: .childRunId)
        captureResponse =
            try container.decodeIfPresent(Bool.self, forKey: .captureResponse) ?? false
        resolved = try container.decodeIfPresent(String.self, forKey: .resolved)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encode(message, forKey: .message)
        try container.encode(type.raw, forKey: .type)
        try container.encodeIfPresent(childRunId, forKey: .childRunId)
        try container.encode(captureResponse, forKey: .captureResponse)
        try container.encodeIfPresent(resolved, forKey: .resolved)
    }

    /// camelCase, unlike the run's own snake_case keys. That asymmetry is real in Archon's
    /// output — `ApprovalContext` is a TypeScript interface serialised as-is, where the run row
    /// is a database record — and it is the same split `ArchonNode` documents.
    private enum CodingKeys: String, CodingKey {
        case nodeId, message, type, childRunId, captureResponse, resolved
    }
}

// MARK: - Acting on one

/// The two verbs helm offers on a gate.
///
/// **Two of Archon's four run-scoped verbs, and the other two are absent on purpose.**
/// `abandon` ends a run rather than answering a gate, and #147 removed it along with the row it
/// lived on; `resume` is not this shape of call at all (see `ArchonClient.resume(_:)`). This
/// enum is the gate's vocabulary, not Archon's whole surface.
enum ArchonGateDecision: String, Equatable, Sendable, CaseIterable {
    case approve, reject

    /// What Archon calls it, and what the operator reads. The same word deliberately: a control
    /// named for something other than the CLI verb it runs is a translation nobody asked for.
    var verb: String { rawValue }

    /// **The flag form, not the positional one.** Archon takes the text either way — `values.comment
    /// || positionals.slice(3).join(' ')` — but a positional loses a reason that begins with a
    /// dash and joins a multi-word one back together on spaces. The flag passes the operator's
    /// sentence through whole.
    func arguments(for runID: String, text: String?) -> [String] {
        let flag = self == .approve ? "--comment" : "--reason"
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let carried = (trimmed?.isEmpty == false) ? [flag, trimmed!] : []
        return ["workflow", verb, runID, "--json"] + carried
    }
}

/// What the composer is pointed at while a gate is being answered.
///
/// **The run id rather than the run**, so a poll that lands mid-typing cannot leave the
/// composer holding a stale copy of a row that has since changed. The workflow name rides along
/// only because the armed header names it and the run may vanish from the list underneath.
struct ArchonGateReply: Equatable, Sendable {
    let runID: String
    let decision: ArchonGateDecision
    let workflowName: String
}

/// One line of JSON from `workflow approve` or `workflow reject`.
///
/// **`ok` is the whole contract, and the exit status is not.** In `--json` mode these commands
/// catch their own failures, print `{"ok": false, …, "error": "…"}` and then return zero. A
/// caller that trusts the exit status reports "approved" for a run that was never found, which
/// is the failure this type exists to make impossible.
///
/// Everything but `ok`, `runId` and `action` is optional because the two verbs answer with two
/// different subsets: `approve` sends `type` and `resumable`, `reject` sends `cancelled`,
/// `maxAttemptsReached` and `resumable`.
struct ArchonActionAcknowledgement: Codable, Equatable, Sendable {
    let ok: Bool
    let runId: String
    let action: String
    let workflowName: String?
    /// `reject` only. False means the run went to an `on_reject` rework rather than ending.
    let cancelled: Bool?
    let maxAttemptsReached: Bool?
    /// True means Archon recorded the decision and parked a run that now needs driving.
    let resumable: Bool?
    /// Present exactly when `ok` is false.
    let error: String?

    /// Whether this acknowledgement leaves a run helm should now resume.
    var leavesRunResumable: Bool { ok && resumable == true }
}
