import Foundation
import HelmWire

/// What a session wants from the operator, in the order the agents tab lists it: ● it waits on
/// him, ✓ its turn ended and he has not looked, ○ it works, then, dimmed, ✓ a turn he has seen and
/// ✓ a session that ended. From what benchd says of the row (#623): `done`, mail to him, and the
/// harness's own activity word.
package enum Attention: Comparable, Sendable {
    case asking
    case finished
    case working
    case seen
    case ended

    package init(_ row: BenchSessionRow) {
        guard case let .running(activity, _) = row.state else {
            self = .ended
            return
        }
        if ["waiting", "blocked"].contains(activity) || (row.operatorMail?.unread ?? 0) > 0 {
            self = .asking
        } else if let done = row.done {
            self = done.seen ? .seen : .finished
        } else {
            // A harness whose hooks do not report a turn's end still says idle.
            self = activity == "idle" ? .seen : .working
        }
    }

    package var glyph: String {
        switch self {
        case .asking: "●"
        case .finished, .seen, .ended: "✓"
        case .working: "○"
        }
    }
}

extension BenchSessionRow {
    /// What Pocket calls a session: its mailbox handle, the name agents and the operator address
    /// it by, else its pane name, its branch, or the start of its id.
    package var title: String {
        handle ?? name ?? branch ?? String(id.prefix(8))
    }

    /// An orchestrator: a session the operator started himself (`spawner: operator`), which home
    /// lists first.
    package var isOrchestrator: Bool { spawner == .operator }

    /// The target `screen/get` and `screen/send` take for this row, when its session runs on the
    /// bench: the session id, or the pane showing it. nil for a row with no screen to show.
    package var screen: String? {
        switch open {
        case let .benchAttach(session): session
        case let .focusPane(pane): pane.uuidString.lowercased()
        case .claudeAttach, .resume, .transcript: nil
        }
    }
}

/// One workspace on the home screen: its folder's name and the sessions Pocket can talk to.
package struct PocketGroup: Equatable, Sendable, Identifiable {
    package var path: String
    package var rows: [BenchSessionRow]

    package var id: String { path }
    package var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

package enum PocketHome {
    /// Each workspace in the document's order, with its sessions that have a screen: the
    /// orchestrators first, then the rest, each in benchd's order (`sessions/all`: running first,
    /// newest first).
    package static func groups(
        workspaces: [String], sessions: [String: [BenchSessionRow]]
    )
        -> [PocketGroup]
    {
        workspaces.map { path in
            let rows = (sessions[path] ?? []).filter { $0.screen != nil }
            return PocketGroup(
                path: path,
                rows: rows.filter(\.isOrchestrator) + rows.filter { !$0.isOrchestrator })
        }
    }

    /// Every session once, however many workspaces list it (by id, as the row is `Identifiable`),
    /// by its `Attention`, newest first within each.
    package static func agents(sessions: [String: [BenchSessionRow]]) -> [BenchSessionRow] {
        var seen = Set<String>()
        let unique = sessions.values.joined().filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            let (aWants, bWants) = (Attention(a), Attention(b))
            if aWants != bWants { return aWants < bWants }
            return a.lastMs > b.lastMs
        }
    }
}

extension BenchSessionRow {
    /// When it last changed: its finish for a finished row.
    package var lastMs: UInt64 {
        if case let .finished(atMs) = state { atMs } else { updatedAtMs }
    }
}

/// A key on the talk screen's keys row, sent as keys (`screen/send keys: true`) so a program with
/// bracketed paste on reads it as the key and not as pasted text.
package enum PocketKey: CaseIterable, Sendable {
    case enter, escape, interrupt, one, two, three, tab, up, down, left, right

    package var label: String {
        switch self {
        case .enter: "⏎"
        case .escape: "esc"
        case .interrupt: "^c"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .tab: "⇥"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }

    /// The bytes a terminal sends for it. Arrows are the normal cursor-key form; `screen/get`
    /// does not say when a program switched to the application form.
    package var bytes: String {
        switch self {
        case .enter: "\r"
        case .escape: "\u{1b}"
        case .interrupt: "\u{3}"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .tab: "\t"
        case .up: "\u{1b}[A"
        case .down: "\u{1b}[B"
        case .left: "\u{1b}[D"
        case .right: "\u{1b}[C"
        }
    }

    package var input: BenchScreenInput { .keys(bytes) }
}
