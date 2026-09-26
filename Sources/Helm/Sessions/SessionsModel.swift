import Foundation
import HelmWire

/// The sessions drawer's list (#384): every agent session in the active workspace, as benchd's
/// `sessions/all` answers it, and the one action each row opens with.
///
/// **No rules of its own.** Which sessions belong to the workspace, their order (running first,
/// then newest), whether a subagent is still listed, and what opening a row does are all
/// benchd's (`bench_sessions`). This carries the answer out and says when it could not ask.
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
    /// The row the keyboard is on.
    @Published var selected: BenchSessionRow.ID?

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
            if selected.map({ id in !rows.contains { $0.id == id } }) ?? true {
                selected = rows.first?.id
            }
        case let .failure(error):
            problem = "Could not list sessions: \(error)"
        }
    }

    /// Carry out the row's own action, then get the drawer out of the way — except for a
    /// transcript, which opens beside the bench rather than instead of it, and for a failure,
    /// which the drawer has to stay open to show.
    func open(_ row: BenchSessionRow) async {
        switch row.open {
        case let .focusPane(pane):
            actions.hideDrawer()
            actions.send(.paneShow(pane))
        case let .transcript(path, _):
            actions.hideDrawer()
            actions.send(.paneOpen(surface: .canvas(path: path)))
        case let .benchAttach(session):
            await run(["bench", "attach", session], in: nil)
        case let .claudeAttach(job):
            await run(["claude", "attach", job], in: nil)
        case let .resume(argv, cwd):
            await run(argv, in: cwd)
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

    private func run(_ argv: [String], in cwd: String?) async {
        let line =
            (cwd.map { "cd \(SpoolLaunchLine.quoted($0)) && " } ?? "")
            + argv.map(SpoolLaunchLine.quoted).joined(separator: " ")
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
