import Foundation

/// `archon workflow attention --json`: every paused run in the workspace's project that needs
/// someone, as Archon's own typed items.
///
/// **The queue is Archon's answer, not helm's.** The drawer used to work out "waiting on you"
/// from `metadata.approval` on each paused run, which only ever knew legacy `approval:` gates.
/// Every SDLC stage now pauses as a `wait: attention` item (Archon 0.12), and those carry their
/// question in `metadata.wait`, so the drawer showed them as paused rows with nothing to press.
/// Archon resolves sub-run chains, fan-out children and unreadable pauses into this one list;
/// helm draws it.
struct ArchonAttentionResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let items: [ArchonAttentionItem]
    let error: String?
}

struct ArchonAttentionItem: Decodable, Equatable, Sendable {
    let runId: String
    let workflow: String
    let pausedAt: Date?
    let context: Context
    let ask: Ask

    struct Context: Decodable, Equatable, Sendable {
        let workingPath: String?
        let branch: String?
    }

    struct Option: Decodable, Equatable, Sendable {
        let id: String
        let label: String?
    }

    /// Archon's `kind`, with what each one carries. Open: an unknown kind costs the item its
    /// controls, never the queue its decode.
    enum Ask: Equatable, Sendable {
        /// A `wait: attention` pause, answered in its form.
        case question(
            node: String, occurrence: String, message: String, form: String, options: [Option])
        /// A deprecated `approval:` gate.
        case gate(node: String, occurrence: String, message: String)
        /// Paused on a provider limit; Archon tries again by itself at `resetAt`.
        case usageLimit(node: String, resetAt: Date?)
        /// A paused run nothing can describe: someone has to look, then resume or abandon it.
        case unreadable(detail: String)
        case unknown(kind: String)
    }

    /// What the operator answers this item with from the drawer, in Archon's order.
    ///
    /// Every answer is one `workflow respond <run> <id>`: Archon maps a declared option, and
    /// `approve` with text on a `message` wait, onto the answer itself. A `multi_select` takes
    /// several ids at once, which `respond` cannot carry, so it offers nothing here and is
    /// answered from a terminal. None of the SDLC workflows asks one.
    var choices: [ArchonChoice] {
        switch ask {
        case let .question(_, _, _, form, options):
            switch form {
            case "select", "approval":
                return options.map { ArchonChoice(id: $0.id, label: $0.label ?? $0.id) }
            case "message":
                return [ArchonChoice(id: "approve", label: "answer", needsText: true)]
            default:
                return []
            }
        case .gate:
            return [
                ArchonChoice(id: "approve", label: "approve"),
                // A legacy reject's reason is the `on_reject` rework prompt; a rework told
                // only that it failed redoes the same work.
                ArchonChoice(id: "reject", label: "reject", needsText: true),
            ]
        case .usageLimit, .unreadable, .unknown:
            return []
        }
    }

    /// Which pause an answer is for. Sent with it, so an answer to a question that has since
    /// moved on is refused by Archon instead of landing on one the operator never read.
    var occurrence: String? {
        switch ask {
        case let .question(_, occurrence, _, _, _), let .gate(_, occurrence, _): occurrence
        default: nil
        }
    }

    /// The text to read: Archon's question, or why nothing can be answered.
    var message: String {
        switch ask {
        case let .question(_, _, message, form, _):
            form == "multi_select"
                ? message + "\n\nSeveral choices at once: answer with `archon workflow answer`."
                : message
        case let .gate(_, _, message): message
        case let .usageLimit(node, resetAt):
            "\(node) hit a provider usage limit. Archon tries again "
                + (resetAt.map { "at \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? "by itself")
                + "."
        case let .unreadable(detail): detail
        case let .unknown(kind): "This Archon is newer than helm: an item of kind \(kind)."
        }
    }

    var isUnreadable: Bool {
        if case .unreadable = ask { return true }
        return false
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decode(String.self, forKey: .runId)
        workflow = try container.decode(String.self, forKey: .workflow)
        pausedAt = try container.decodeIfPresent(Date.self, forKey: .pausedAt)
        context = try container.decode(Context.self, forKey: .context)
        let kind = try container.decode(String.self, forKey: .kind)
        func string(_ key: CodingKeys) throws -> String {
            try container.decode(String.self, forKey: key)
        }
        switch kind {
        case "attention":
            ask = .question(
                node: try string(.node), occurrence: try string(.occurrence),
                message: try string(.message), form: try string(.form),
                options: try container.decode([Option].self, forKey: .options))
        case "awaiting_response":
            ask = .gate(
                node: try string(.node), occurrence: try string(.occurrence),
                message: try string(.message))
        case "usage_limit":
            ask = .usageLimit(
                node: try string(.node),
                resetAt: try container.decodeIfPresent(Date.self, forKey: .resetAt))
        case "unreadable":
            ask = .unreadable(detail: try string(.detail))
        default:
            ask = .unknown(kind: kind)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case runId, workflow, pausedAt, context, kind, node, occurrence, message, form, options
        case resetAt, detail
    }
}

/// One answer an item offers: the id `respond` sends and the words the drawer shows.
struct ArchonChoice: Equatable, Sendable {
    let id: String
    let label: String
    /// True when the answer is nothing without text: a `message` wait's answer is the text,
    /// and a legacy gate's reject reason is its rework prompt.
    var needsText = false
}

/// What the composer is pointed at while an item is being answered. The run id and
/// occurrence rather than the item, so a poll that lands mid-typing cannot leave the composer
/// holding a stale copy.
struct ArchonAnswer: Equatable, Sendable {
    let runID: String
    let occurrence: String
    let choice: ArchonChoice
    let workflowName: String

    /// `respond` records the answer and `--detach` hands its continuation to a child process:
    /// with no `archon serve` running, an answer recorded with bare `--json` would sit there.
    /// Text goes by flag, so a reason that starts with a dash survives. Whitespace-only is no
    /// text at all.
    func arguments(text: String?) -> [String] {
        let command = [
            "workflow", "respond", runID, choice.id, "--occurrence", occurrence, "--detach",
            "--json",
        ]
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return command }
        return command + ["--text", text]
    }
}

/// The line a `--json` control verb (`respond`, `resume`, `cancel`) prints. `ok` is the
/// contract: a refusal prints `{"ok": false, "error": …}`, and since Archon 0.12 also exits 1,
/// which `ArchonCLI` reads back into the refusal.
struct ArchonActionAcknowledgement: Codable, Equatable, Sendable {
    let ok: Bool
    let runId: String?
    let action: String?
    /// `--detach` verbs: a child process now drives the run onward.
    let continues: Bool?
    let error: String?
}
