import Foundation
import HelmWire

/// One workspace on the home screen (operator, 2026-10-03): its running sessions, the
/// orchestrators first, and its finished ones apart, behind a disclosure.
package struct PocketSection: Equatable, Sendable, Identifiable {
    package var path: String
    /// Running sessions with a screen to talk to: the ones asking for him first, then the
    /// orchestrators (`spawner: operator`), then the rest, each in benchd's order.
    package var running: [BenchSessionRow]
    /// The newest finished sessions, at most `PocketHome.finishedShown`.
    package var finished: [BenchSessionRow]
    /// Every finished session, shown or not.
    package var finishedCount: Int
    /// A running session it shows waits on the operator or finished a turn he has not seen.
    package var needsHim: Bool
    /// One of them waits on him: the section tops the list.
    package var asking: Bool
    /// When anything in it last changed.
    package var lastActive: UInt64

    package var id: String { path }
    package var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

extension PocketHome {
    /// How many finished sessions a section shows: the newest. A workspace that ran tests can
    /// hold a hundred.
    package static let finishedShown = 10

    /// Each workspace as a section: one with a chat asking for him first, then the ones that need
    /// him, then the ones with something running, each most recently active first.
    /// A non-empty `query` keeps only the sessions whose title, name, handle, branch or model has
    /// it (any case), and only the sections left with one.
    package static func sections(
        workspaces: [String], sessions: [String: [BenchSessionRow]], query: String
    ) -> [PocketSection] {
        let words = query.trimmingCharacters(in: .whitespaces)
        let all = workspaces.map { path in
            section(path, (sessions[path] ?? []).filter { words.isEmpty || $0.matches(words) })
        }
        let shown = words.isEmpty ? all : all.filter { !$0.running.isEmpty || $0.finishedCount > 0 }
        return shown.sorted { a, b in
            if a.asking != b.asking { return a.asking }
            if a.needsHim != b.needsHim { return a.needsHim }
            if a.running.isEmpty != b.running.isEmpty { return !a.running.isEmpty }
            return a.lastActive > b.lastActive
        }
    }

    private static func section(_ path: String, _ rows: [BenchSessionRow]) -> PocketSection {
        let running = rows.filter { $0.isRunning && $0.screen != nil }
        let finished = rows.filter { !$0.isRunning }.sorted { $0.lastMs > $1.lastMs }
        return PocketSection(
            path: path,
            running: running.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element),
            finished: Array(finished.prefix(finishedShown)), finishedCount: finished.count,
            // Of what it shows: a session with no screen to open cannot be what he is sent to.
            needsHim: running.contains { [.asking, .finished].contains(Attention($0)) },
            asking: running.contains { Attention($0) == .asking },
            lastActive: rows.map(\.lastMs).max() ?? 0)
    }
}

extension PocketHome {
    /// The chat `step` places from `id` in its own section (-1 the one above, 1 below), for a
    /// swipe inside a chat; nil at either end, or when `id` is in no section.
    package static func neighbor(
        of id: String, in sections: [PocketSection], step: Int
    )
        -> BenchSessionRow?
    {
        for section in sections {
            guard let at = section.running.firstIndex(where: { $0.id == id }) else { continue }
            let next = at + step
            return section.running.indices.contains(next) ? section.running[next] : nil
        }
        return nil
    }

    /// A chat that asks for him first, then the orchestrators, then the rest. The caller ties a
    /// rank by benchd's order: Swift does not promise a stable sort.
    fileprivate static func rank(_ row: BenchSessionRow) -> Int {
        if Attention(row) == .asking { return 0 }
        return row.isOrchestrator ? 1 : 2
    }
}

extension BenchSessionRow {
    fileprivate var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    fileprivate func matches(_ words: String) -> Bool {
        [title, name, handle, branch, model].compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(words) }
    }
}
