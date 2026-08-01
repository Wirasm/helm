import Foundation

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
/// helm holds **no state of its own** here. The registry file's lifecycle is the
/// mark's lifecycle — no acknowledge, no decay, no wallclock. Nothing clears a
/// mark except the agent going back to work or its session ending. That is what
/// makes this the only stateless option, and why it is safe to poll and republish
/// rather than accumulate.
@MainActor
final class BoardModel: ObservableObject {
    /// The app's one board — there is one session registry on this machine.
    /// Mirrors `TerminalManager.shared`; `init` stays internal so tests can build
    /// isolated boards over a fixture directory.
    static let shared = BoardModel(manager: .shared)

    /// Keyed by `Workspace.path`. A workspace missing from this dictionary is
    /// unmarked — which is why it is a dictionary of presences rather than a
    /// presence for every known workspace.
    @Published private(set) var presence: [String: AgentPresence] = [:]

    private let manager: TerminalManager
    private let root: URL

    init(manager: TerminalManager, root: URL = AgentRegistry.defaultRoot) {
        self.manager = manager
        self.root = root
    }

    /// Polls until cancelled — driven from `WorkspaceBar`'s `.task`, so its lifetime
    /// is the window's and SwiftUI cancels it on teardown.
    ///
    /// Polling, not watching: a status change rewrites an existing file, which the
    /// directory-level `DispatchSource` pattern (`ArtifactPane`'s `FileWatcher`)
    /// would not reliably see. Two seconds is well inside glance latency and costs
    /// one directory listing plus a handful of ~400-byte reads, off the main actor.
    func poll(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// One tick: read the registry off the main actor, join it against the pids
    /// helm's own surfaces are running, and republish the whole map. Republishing
    /// wholesale is the point — a mark that is gone from the registry is gone from
    /// the board in the same tick, with nothing to expire.
    func refresh() async {
        let hosted = hostedPids()
        let root = self.root
        let rows = await Task.detached { AgentRegistry.sessions(in: root) }.value
        presence = hosted.compactMapValues { BoardModel.presence(of: rows, hosted: $0) }
    }

    /// Foreground pid of every live surface, grouped by workspace.
    ///
    /// Reads `TerminalManager.sessions`, which is flat and app-wide and keeps a
    /// parked workspace's terminals alive across a switch. That is the whole point:
    /// a board that could only see the workspace you are looking at would report
    /// nothing worth knowing.
    private func hostedPids() -> [String: Set<pid_t>] {
        var pids: [String: Set<pid_t>] = [:]
        for session in manager.sessions {
            guard let pid = session.hostView.foregroundPid else { continue }
            pids[session.workspacePath, default: []].insert(pid)
        }
        return pids
    }

    /// One workspace's mark, from the whole registry and that workspace's pids.
    ///
    /// **The pid match is the attribution, not `cwd`.** Verified live: the registry
    /// held six rows and exactly one was helm-hosted; of the five that were not, one
    /// shared the same `cwd` and one was `busy`. Matching on `cwd` would have lit a
    /// workspace for another editor's agent.
    ///
    /// It also makes ghost rows impossible: a stale row for a dead pid matches no
    /// live surface. There is no freshness check because there could not be one —
    /// `statusUpdatedAt` is a last-transition time, not a heartbeat.
    ///
    /// A row with no recognised `status` contributes nothing, so a workspace whose
    /// only agent is mid-transition stays unmarked rather than guessing at it.
    ///
    /// Known and accepted: a stale row whose pid has been reused by another process
    /// helm hosts would mark falsely. Guarding on `cwd` would break an agent started
    /// from a subdirectory, and the window closes the moment either side writes.
    ///
    /// `nonisolated` because it genuinely is — it reads no model state, which is what
    /// lets the acceptance rules be tested without a main actor, a window or a pty.
    nonisolated static func presence(of rows: [AgentSession], hosted: Set<pid_t>) -> AgentPresence?
    {
        let mine = rows.compactMap { hosted.contains($0.pid) ? $0.status : nil }
        guard !mine.isEmpty else { return nil }
        return mine.allSatisfy(\.isWorking) ? .working : .notWorking
    }
}
