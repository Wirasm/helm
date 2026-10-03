import Foundation
import HelmWire

/// The sessions drawer's list (#384): every agent session in the active workspace, as benchd's
/// `sessions/all` answers it, and the one action each row opens with.
///
/// **Which sessions belong, and their order, are benchd's.** Which sessions belong to the
/// workspace, their order (running first, then newest), whether a subagent is still listed, and
/// what opening a row does are all benchd's (`bench_sessions`). The one rule here is how much of
/// that the drawer shows: running sessions always, finished ones only once the operator opens
/// them for this workspace, the newest few (`listed`). benchd's answer stays whole, as `bench
/// sessions --all` gives it to agents, who resume finished sessions from it.
///
/// **Polled while it is on screen, and only then.** benchd pushes no event when a session
/// changes, so the view's `.task` calls `watch`, which asks every few seconds and stops when the
/// drawer is hidden.
@MainActor
final class SessionsModel: ObservableObject {
    @Published private(set) var rows: [BenchSessionRow] = []
    /// Why the list may be incomplete or stale: benchd unreachable or refusing, or files it could
    /// not read. nil when the list is whole.
    @Published private(set) var problem: String?
    /// The row the keyboard is on; nil while it is on the finished line.
    @Published var selected: BenchSessionRow.ID?
    /// The keyboard is on the "finished" line, where Return opens or closes it.
    @Published private(set) var onFinishedLine = false
    /// The workspaces whose finished sessions the operator has opened, by path.
    @Published private var finishedOpen: Set<String> = []

    /// How many finished sessions the drawer lists once opened: the newest. A workspace an
    /// agent harness runs tests in can hold ninety.
    static let finishedListed = 10

    private let actions: SessionsActions

    init(actions: SessionsActions) {
        self.actions = actions
    }

    var workspace: WorkspacePath? { actions.workspace() }

    /// Asks until cancelled. Driven by the view's `.task(id:)` on the workspace, so it restarts
    /// when the operator switches workspace and stops when the drawer is hidden.
    func watch(every interval: Duration = .seconds(3)) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func refresh() async {
        guard let workspace else {
            rows = []
            problem = "No workspace is open."
            keepSelectionListed()
            return
        }
        let list = actions.list
        let path = workspace.value
        let answer = await Task.detached { Result { try list(path) } }.value
        switch answer {
        case let .success(list):
            rows = list.rows
            problem =
                list.unreadable.isEmpty
                ? nil
                : "\(list.unreadable.count) session file(s) benchd could not read were skipped."
            keepSelectionListed()
        case let .failure(error):
            problem = "Could not list sessions: \(error)"
        }
    }

    /// The running sessions, in benchd's order.
    var running: [BenchSessionRow] { rows.filter(SessionLine.isRunning) }
    /// The finished sessions, newest first as benchd orders them.
    var finished: [BenchSessionRow] { rows.filter { !SessionLine.isRunning($0) } }

    /// Whether this workspace's finished sessions are open.
    var showsFinished: Bool { workspace.map { finishedOpen.contains($0.value) } ?? false }

    /// What the drawer lists, in order: every running session, then, once opened, the newest
    /// finished ones up to `finishedListed`.
    var listed: [BenchSessionRow] {
        running + (showsFinished ? Array(finished.prefix(Self.finishedListed)) : [])
    }

    /// Open or close this workspace's finished sessions.
    func toggleFinished() {
        guard let path = workspace?.value else { return }
        if finishedOpen.remove(path) == nil { finishedOpen.insert(path) }
        keepSelectionListed()
    }

    /// Where ↑↓ stop: the running rows, the finished line when there is anything finished, then
    /// the finished rows it lists once opened. nil is the finished line.
    var stops: [BenchSessionRow.ID?] {
        running.map(\.id) + (finished.isEmpty ? [] : [nil])
            + (showsFinished ? finished.prefix(Self.finishedListed).map(\.id) : [])
    }

    /// Move the keyboard `step` stops, stopping at either end. false when there is nowhere to go.
    func move(_ step: Int) -> Bool {
        let stops = stops
        guard !stops.isEmpty else { return false }
        let here = onFinishedLine ? nil : selected
        let current = stops.firstIndex { $0 == here } ?? -1
        land(on: stops[min(max(current + step, 0), stops.count - 1)])
        return true
    }

    private func land(on stop: BenchSessionRow.ID?) {
        onFinishedLine = stop == nil
        selected = stop
    }

    /// The keyboard stays on something the drawer shows: its row, else the first stop (the
    /// finished line, in a workspace where nothing runs).
    private func keepSelectionListed() {
        let stops = stops
        let somewhere = onFinishedLine || selected != nil
        if somewhere, stops.contains(onFinishedLine ? nil : selected) { return }
        if let first = stops.first {
            land(on: first)
        } else {
            selected = nil
            onFinishedLine = false
        }
    }

    /// Go to the pane of an agent that needs the operator (M1, #357), as his own gesture: focus
    /// arriving there is what marks a finished turn seen. One with no pane goes nowhere.
    func goTo(_ item: AttentionItem) {
        guard let pane = item.pane else { return }
        actions.hideDrawer()
        actions.send(.paneShow(pane))
    }

    /// Hide the drawer, then carry out the row's own action, so the keyboard lands on what the
    /// action opened. A terminal that could not run its line leaves the reason on `problem`.
    func open(_ row: BenchSessionRow) async {
        switch row.open {
        case let .focusPane(pane):
            actions.hideDrawer()
            actions.send(.paneShow(pane))
        case let .transcript(path, _):
            actions.hideDrawer()
            actions.send(.paneOpen(surface: .canvas(path: path)))
        case let .benchAttach(session):
            // A pane that shows the session, as `bench spawn` makes one: benchd opens it, and
            // helm shows it with the `bench` it resolved (`BenchExecutable`), never a bare name.
            actions.hideDrawer()
            actions.send(.paneOpen(surface: .terminal(agent: nil, session: session)))
        case let .claudeAttach(job):
            await run(["claude", "attach", job])
        case let .resume(_, cwd):
            // Through benchd rather than the row's argv typed into a shell: benchd tells the
            // agent it was resumed, and brings back the worktree it ran in when that is gone
            // (#621).
            actions.hideDrawer()
            let resume = actions.resume
            let (harness, id) = (row.harness, row.id)
            let answer = await Task.detached { Result { try resume(harness, id, cwd) } }.value
            if case let .failure(error) = answer {
                problem = "Could not resume \(id): \(error)"
            }
        }
    }

    /// Take a finished session off the list. benchd keeps the record; the harness's own files
    /// are untouched.
    func dismiss(_ row: BenchSessionRow) async {
        guard case .finished = row.state else { return }
        let dismiss = actions.dismiss
        let (harness, id) = (row.harness, row.id)
        let answer = await Task.detached { Result { try dismiss(harness, id) } }.value
        if case let .failure(error) = answer {
            problem = "Could not dismiss \(row.id): \(error)"
            return
        }
        await refresh()
    }

    private func run(_ argv: [String]) async {
        let line = argv.map(LaunchLine.quoted).joined(separator: " ")
        actions.hideDrawer()
        if let failure = await actions.runInNewTerminal(line) {
            problem = failure
        }
    }
}

/// What the list needs from outside it: benchd for the rows, and the bench for the actions.
/// Closures, so a test says what benchd answers and records what the bench was asked.
struct SessionsActions {
    /// `sessions/all` for a workspace path. Blocking; called off the main actor.
    var list: @Sendable (_ workspace: String) throws -> BenchSessionList
    /// `sessions/dismiss`. Blocking; called off the main actor.
    var dismiss: @Sendable (_ harness: String, _ id: String) throws -> Void
    /// `spawn --resume` of conversation `id` where it ran, as the operator. Blocking; called off
    /// the main actor.
    var resume: @Sendable (_ harness: String, _ id: String, _ cwd: String) throws -> Void
    /// The workspace on screen.
    var workspace: @MainActor () -> WorkspacePath?
    /// A bench verb, as the operator: he pressed the row.
    var send: @MainActor (BenchVerb) -> Void
    /// Hide the drawer the list is shown in, if one is shown.
    var hideDrawer: @MainActor () -> Void
    /// Open a terminal on the bench and run `line` in it once its shell is up. nil when it ran,
    /// else why not.
    var runInNewTerminal: @MainActor (_ line: String) async -> String?
}
