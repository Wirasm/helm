import Foundation
import HelmWire

/// What a session wants from the operator, as one glyph: ● it waits on him, ✓ its turn is over,
/// ○ it is working. Read from the harness's own activity word until benchd says it outright
/// (#623's `done`).
package enum Attention: Equatable, Sendable {
    case asking
    case finished
    case working

    package init(_ row: BenchSessionRow) {
        switch row.state {
        case .finished: self = .finished
        case let .running(activity, _):
            switch activity {
            case "waiting", "blocked": self = .asking
            case "idle": self = .finished
            default: self = .working
            }
        }
    }

    package var glyph: String {
        switch self {
        case .asking: "●"
        case .finished: "✓"
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
    /// Each workspace in the document's order, with its sessions that have a screen, in benchd's
    /// order (`sessions/all`: running first, newest first).
    package static func groups(
        workspaces: [String], sessions: [String: [BenchSessionRow]]
    )
        -> [PocketGroup]
    {
        workspaces.map { path in
            PocketGroup(path: path, rows: (sessions[path] ?? []).filter { $0.screen != nil })
        }
    }

    /// Every session once, however many workspaces list it (by id, as the row is `Identifiable`),
    /// in benchd's order: running first, then newest first.
    package static func agents(sessions: [String: [BenchSessionRow]]) -> [BenchSessionRow] {
        var seen = Set<String>()
        let unique = sessions.values.joined().filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            let (aRuns, bRuns) = (a.isRunning, b.isRunning)
            if aRuns != bRuns { return aRuns }
            return a.lastMs > b.lastMs
        }
    }
}

extension BenchSessionRow {
    fileprivate var isRunning: Bool {
        if case .running = state { true } else { false }
    }

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
