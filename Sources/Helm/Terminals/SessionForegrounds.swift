import Foundation
import HelmWire

/// What benchd says about each terminal pane's session (M5b, #359; M1, #357): what has its
/// terminal, and whether the agent in it is waiting on the operator.
///
/// Every terminal pane shows a benchd session now, so the pty helm's own surface holds runs
/// `bench attach`, and its foreground process says nothing about the agent in the pane. benchd
/// owns the real pty and answers `sessions` with its foreground process: the shell, or the job
/// the shell is running (a `claude`, say). That pid is what presence and the pane's agent join
/// against Claude's registry, exactly as helm's own pty's was. The same answer carries benchd's
/// `waiting`: the agent's own report, or a prompt benchd read off its screen, which is the only
/// way helm learns that a codex or pi is waiting.
///
/// Refreshed off the main actor on the agent watch's two-second tick, and read synchronously by
/// everything that wants a pane's pid. Nothing polls in a test: only `refresh` reaches benchd.
@MainActor
final class SessionForegrounds: ObservableObject {
    private var byPane: [UUID: pid_t] = [:]
    /// The agents waiting on the operator, by the pane showing each. Published: the status
    /// bar counts them.
    @Published private(set) var waiting: [UUID: BenchLiveSessions.Waiting] = [:]

    /// The foreground pid of the session `pane` shows, as of the last refresh.
    func pid(ofPane pane: UUID) -> pid_t? { byPane[pane] }

    /// Ask benchd again. A failed ask keeps the last answer: presence goes stale for a tick
    /// rather than blinking out while benchd restarts.
    func refresh(using client: BenchClient) async {
        let answer = await Task.detached {
            try? client.request(
                BenchLiveSessionsRequest(id: "helm-sessions-\(UUID().uuidString)"),
                answering: BenchLiveSessions.self)
        }.value
        guard let live = answer?.data, answer?.status == .ok else { return }
        byPane = live.foregroundByPane.mapValues { pid_t($0) }
        let waiting = live.waitingByPane
        if waiting != self.waiting { self.waiting = waiting }
    }

    /// Set directly, for tests that say what benchd would answer.
    func set(_ pids: [UUID: pid_t], waiting: [UUID: BenchLiveSessions.Waiting] = [:]) {
        byPane = pids
        self.waiting = waiting
    }
}
