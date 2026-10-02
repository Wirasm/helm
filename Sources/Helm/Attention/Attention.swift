import Foundation
import HelmWire

/// Why an agent needs the operator (M1, #357), in the order he works through them: ⌘⇧J walks
/// them in this order too (benchd's `focus/waiting`).
enum AttentionKind: Int, Comparable, CaseIterable {
    /// It is asking him something: a permission, trust or question prompt. Always his.
    case asking
    /// Its turn ended and he has not looked at its pane since.
    case finished
    /// It mailed him and he has not read it.
    case message

    static func < (a: AttentionKind, b: AttentionKind) -> Bool { a.rawValue < b.rawValue }

    /// The mark, the same everywhere it is drawn.
    var glyph: String {
        switch self {
        case .asking: "●"
        case .finished: "✓"
        case .message: "✉"
        }
    }
}

/// One thing an agent needs from someone.
struct AttentionItem: Equatable, Identifiable {
    let kind: AttentionKind
    /// The pane showing its session, when one does.
    let pane: UUID?
    /// benchd's session id.
    let session: String
    /// Who: its handle.
    let who: String
    /// The agent's own words for it, when it gave any: what it waits for, the mail's subject.
    let words: String?
    let since: Date
    /// Addressed to the operator. A finished turn of an agent another agent spawned is that
    /// agent's; asking and mail are always his.
    let mine: Bool

    var id: String { "\(kind.rawValue)-\(session)" }
}

/// benchd's attention projection, as helm draws it. helm keeps no attention state of its own:
/// every surface reads these items, rebuilt from each `sessions` answer.
enum Attention {
    /// Everything in `live` that needs someone, by kind and then the oldest first. A finished
    /// turn he has seen is not here: looking is what clears it.
    static func items(_ live: [BenchLiveSessions.Entry]) -> [AttentionItem] {
        live.flatMap(items(of:)).sorted { ($0.kind, $0.since) < ($1.kind, $1.since) }
    }

    private static func items(of entry: BenchLiveSessions.Entry) -> [AttentionItem] {
        let item = { (kind: AttentionKind, words: String?, since: Date, mine: Bool) in
            AttentionItem(
                kind: kind, pane: entry.pane, session: entry.session,
                who: entry.handle ?? entry.session, words: words, since: since, mine: mine)
        }
        var items: [AttentionItem] = []
        if let waiting = entry.waiting {
            items.append(item(.asking, waiting.waitingFor, waiting.since, true))
        }
        if let done = entry.done, !done.seen {
            items.append(item(.finished, nil, done.since, done.to == operatorHandle))
        }
        if let mail = entry.operatorMail {
            items.append(item(.message, mail.subject, mail.since, true))
        }
        return items
    }

    /// The items in `after` that were not asking in `before`: a wait that has just begun, told
    /// once.
    static func newlyAsking(before: [AttentionItem], after: [AttentionItem]) -> [AttentionItem] {
        let asked = Set(before.filter { $0.kind == .asking }.map(\.session))
        return after.filter { $0.kind == .asking && !asked.contains($0.session) }
    }

    /// The operator's own handle on the bench (`bench_wire::OPERATOR_HANDLE`).
    static let operatorHandle = "operator"

    /// How many of his own there are of each kind.
    static func counts(_ items: [AttentionItem]) -> [AttentionKind: Int] {
        Dictionary(grouping: items.filter(\.mine), by: \.kind).mapValues(\.count)
    }

    /// The most urgent of his own items for each pane.
    static func byPane(_ items: [AttentionItem]) -> [UUID: AttentionKind] {
        var marks: [UUID: AttentionKind] = [:]
        for item in items where item.mine {
            guard let pane = item.pane else { continue }
            marks[pane] = min(marks[pane] ?? item.kind, item.kind)
        }
        return marks
    }
}

/// One workspace tab's mark: the most urgent thing an agent there needs from the operator, else
/// that an agent there is working. Absent when neither.
enum WorkspaceMark: Equatable {
    case needs(AttentionKind)
    case working

    /// The marks by workspace, from the panes in each (`panes`: workspace path → its panes), the
    /// marks by pane, and what each pane's agent reports.
    static func of(
        panes: [String: [UUID]], marks: [UUID: AttentionKind],
        reports: [UUID: BenchLiveSessions.Report]
    ) -> [String: WorkspaceMark] {
        panes.compactMapValues { panes in
            if let kind = panes.compactMap({ marks[$0] }).min() { return .needs(kind) }
            let working = panes.contains { reports[$0].map { isWorking($0.activity) } ?? false }
            return working ? .working : nil
        }
    }

    /// Every workspace's mark, from the terminals `manager` holds (app-wide, a parked workspace's
    /// among them) and what benchd last said about them.
    @MainActor
    static func of(_ manager: TerminalManager) -> [String: WorkspaceMark] {
        let panes = Dictionary(grouping: manager.sessions, by: \.workspacePath.value)
            .mapValues { $0.map(\.id) }
        let foregrounds = manager.foregrounds
        return of(
            panes: panes, marks: Attention.byPane(foregrounds.attention),
            reports: foregrounds.reports)
    }

    /// An agent at work, by its own word: busy, or running a shell command.
    static func isWorking(_ activity: String) -> Bool {
        activity == "busy" || activity == "shell"
    }
}
