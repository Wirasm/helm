import BenchKit
import Foundation
import HelmWire

/// What benchd says about each terminal pane's session (M5b, #359; M1, #357; M5c, #459): what has
/// its terminal, whether the agent in it is waiting on the operator, and what that agent says it
/// is doing.
///
/// Every terminal pane shows a benchd session now, so the pty helm's own surface holds runs
/// `bench attach`, and its foreground process says nothing about the agent in the pane. benchd
/// owns the real pty and answers `sessions` with its foreground process, the agent's `waiting`
/// (its own report, or a prompt benchd read off its screen) and its `report`: Claude Code's
/// registry row for that process, or the agent's last hook, read on benchd's machine. Presence and
/// the snapshot's `agent` read the report, so helm reads no registry and a benchd on another
/// machine lights them all the same.
///
/// Refreshed off the main actor on the agent watch's two-second tick, and read synchronously by
/// everything that wants a pane's pid. Nothing polls in a test: only `refresh` reaches benchd.
@MainActor
final class SessionForegrounds: ObservableObject {
    private var byPane: [UUID: pid_t] = [:]
    /// What each pane's agent says it is doing. Published: the workspace tabs mark an agent at
    /// work.
    @Published private(set) var reports: [UUID: BenchLiveSessions.Report] = [:]
    /// The agents waiting on the operator, by the pane showing each: the snapshot's `agent`.
    @Published private(set) var waiting: [UUID: BenchLiveSessions.Waiting] = [:]
    /// Everything an agent needs from someone (M1, #357): asking, finished unseen, mail to the
    /// operator. Published: the status bar, the Sessions drawer and the tabs draw it.
    @Published private(set) var attention: [AttentionItem] = []
    /// Called with the items that have just started asking: how a desktop notification is posted
    /// for an agent he cannot see (`TerminalManager`).
    var onAsking: (([AttentionItem]) -> Void)?
    /// Each harness's plan limits as benchd last heard them (#143). Published: the status bar
    /// shows them.
    @Published private(set) var usage: [BenchUsage] = []

    /// The foreground pid of the session `pane` shows, as of the last refresh.
    func pid(ofPane pane: UUID) -> pid_t? { byPane[pane] }

    /// What the agent in the session `pane` shows says it is doing, as of the last refresh.
    func report(ofPane pane: UUID) -> BenchLiveSessions.Report? { reports[pane] }

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
        let reports = live.reportByPane
        if reports != self.reports { self.reports = reports }
        let waiting = live.waitingByPane
        if waiting != self.waiting { self.waiting = waiting }
        if live.usage != usage { usage = live.usage }
        take(Attention.items(live.sessions))
    }

    /// Keep what needs someone now, and say which items have just started asking. The first
    /// answer only sets the scene: a wait already open when helm started is not news.
    private func take(_ attention: [AttentionItem]) {
        let asking = Attention.newlyAsking(before: self.attention, after: attention)
        if attention != self.attention { self.attention = attention }
        defer { answered = true }
        if answered, !asking.isEmpty { onAsking?(asking) }
    }

    /// Whether an answer has been taken yet (`take`).
    private var answered = false

    /// Set directly, for tests that say what benchd would answer.
    func set(
        _ pids: [UUID: pid_t], waiting: [UUID: BenchLiveSessions.Waiting] = [:],
        reports: [UUID: BenchLiveSessions.Report] = [:], attention: [AttentionItem] = []
    ) {
        byPane = pids
        self.waiting = waiting
        self.reports = reports
        take(attention)
    }
}
