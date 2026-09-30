import Foundation
import HelmWire

/// What one workspace tab says about its agents. Absent (`nil`) is a real and
/// distinct answer, and the common one: no agent here at all.
enum AgentPresence: Equatable {
    /// Every agent in this workspace is carrying on without you.
    case working
    /// At least one has stopped — finished, or blocked on you. The board does not
    /// distinguish those: both mean it is your turn.
    case notWorking
}

/// The board: which workspace has an agent that needs you, without opening it.
///
/// helm holds **no state of its own** here. What each pane's agent reports is benchd's answer to
/// `sessions` (`SessionForegrounds`): Claude Code's registry row for the process in the pane's
/// session, or the agent's own last hook, read on benchd's machine (M5c). The report's lifecycle
/// is the mark's lifecycle — no acknowledge, no decay, no wallclock. Nothing clears a mark except
/// the agent going back to work or its session ending, which is why it is safe to recompute and
/// republish rather than accumulate.
@MainActor
final class BoardModel: ObservableObject {
    /// The app's one board. Mirrors `TerminalManager.shared`; `init` stays internal so tests can
    /// build isolated boards over their own manager.
    static let shared = BoardModel(manager: .shared)

    /// Keyed by `Workspace.path.value`, matching `WorkspaceModel.contexts` — not persisted
    /// itself, but the same key everything else that indexes on a workspace uses. A workspace
    /// missing from this dictionary is unmarked — which is why it is a dictionary of
    /// presences rather than a presence for every known workspace.
    @Published private(set) var presence: [String: AgentPresence] = [:]

    private let manager: TerminalManager

    init(manager: TerminalManager) {
        self.manager = manager
    }

    /// Recomputes until cancelled — driven from `WorkspaceBar`'s `.task`, so its lifetime is the
    /// window's. The reports it reads are refreshed on the same two-second tick by
    /// `WorkbenchModel.watchForegrounds`.
    ///
    /// A second window would start a second loop against this same shared board. Deliberately
    /// not guarded: both compute the same answer from the same input and this actor serialises
    /// their writes. An "already polling" flag would be worse — closing the first window would
    /// stop the second window's board.
    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// One tick: every live terminal's report, grouped by workspace, and the whole map
    /// republished. Republishing wholesale is the point — a report that is gone is gone from the
    /// board in the same tick, with nothing to expire.
    ///
    /// Reads `TerminalManager.sessions`, which is flat and app-wide and keeps a parked
    /// workspace's terminals alive across a switch. A board that could only see the workspace you
    /// are looking at would report nothing worth knowing.
    func refresh() {
        var reports: [String: [BenchLiveSessions.Report]] = [:]
        for session in manager.sessions {
            guard let report = session.report else { continue }
            reports[session.workspacePath.value, default: []].append(report)
        }
        presence = reports.compactMapValues(BoardModel.presence(of:))
    }

    /// One workspace's mark, from what its panes' agents report.
    ///
    /// **The pane is the attribution**: benchd reads the registry row of the process holding
    /// the terminal of the session a pane shows, so another editor's agent in the same directory
    /// never lights this workspace. A report whose activity is not one the board knows
    /// contributes nothing, so a workspace whose only agent says something new stays unmarked
    /// rather than guessing at it.
    nonisolated static func presence(of reports: [BenchLiveSessions.Report]) -> AgentPresence? {
        let working = reports.compactMap { isWorking($0.activity) }
        guard !working.isEmpty else { return nil }
        return working.allSatisfy { $0 } ? .working : .notWorking
    }

    /// Whether an agent that says `activity` is carrying on without you. `waiting` (blocked on a
    /// prompt) and `idle` (finished) are the same state seen twice: it is your turn. nil for a
    /// word the board does not know. A report says only these four: the registry's statuses and
    /// a hook's busy, idle and waiting.
    nonisolated static func isWorking(_ activity: String) -> Bool? {
        switch activity {
        case "busy", "shell": true
        case "idle", "waiting": false
        default: nil
        }
    }
}
