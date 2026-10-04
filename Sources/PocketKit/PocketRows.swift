import Foundation
import HelmWire

/// What a session wants from the operator: ● it waits on him, ✓ its turn ended and he has not
/// looked, ○ it works, then, dimmed, ✓ a turn he has seen and ✓ a session that ended. From what benchd says of the row (#623): `done`, mail to him, and the
/// harness's own activity word.
package enum Attention: Sendable {
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
            // A turn addressed to the agent that spawned it is that agent's to read.
            self = done.seen || done.to != "operator" ? .seen : .finished
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
    /// The agent itself says it waits on a prompt, not merely that mail to him is unread: when a
    /// chat reads the prompt's choices off its screen.
    package var waitsAtPrompt: Bool {
        if case let .running(activity, _) = state { activity == "waiting" } else { false }
    }

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

package enum PocketHome {
    /// Each session under one workspace: of those `sessions/all` listed it under, the most
    /// specific one its cwd is in, else the first in `workspaces` (a worktree outside every
    /// workspace's folder). benchd lists a session under every workspace whose folder or git
    /// worktrees hold it, so a workspace inside another lists its sessions twice. Each workspace
    /// keeps benchd's order.
    package static func owners(
        _ listed: [String: [BenchSessionRow]], workspaces: [String]
    ) -> [String: [BenchSessionRow]] {
        // The workspaces that listed each session, in document order.
        var listing: [String: [String]] = [:]
        for workspace in workspaces {
            for row in listed[workspace] ?? [] { listing[row.id, default: []].append(workspace) }
        }
        func owner(_ row: BenchSessionRow) -> String? {
            let candidates = listing[row.id] ?? []
            return candidates.filter(row.isIn).max { $0.count < $1.count } ?? candidates.first
        }
        var owned: [String: [BenchSessionRow]] = [:]
        for workspace in workspaces {
            owned[workspace] = (listed[workspace] ?? []).filter { owner($0) == workspace }
        }
        return owned
    }
}

extension BenchSessionRow {
    /// Whether its cwd is `folder` or inside it, by path component.
    fileprivate func isIn(_ folder: String) -> Bool {
        cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
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
