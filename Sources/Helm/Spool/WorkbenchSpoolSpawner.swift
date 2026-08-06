import Foundation
import HelmWire

/// The spool's edge: turns an accepted request into a real pane on the real bench.
///
/// Everything here needs a window, a ghostty surface and a pty, which is exactly why it is
/// separated from `SpoolModel` — the claiming, refusing, timing out and result writing on the
/// other side of `SpoolSpawning` are reachable from `swift test`, and this is not.
///
/// It lives in the spool's own slice rather than in `Workbench/` because it is the spool's
/// adapter onto the bench, not a bench feature. Two people building two features should not
/// have to edit the same file (`AGENTS.md`).
@MainActor
final class WorkbenchSpoolSpawner: SpoolSpawning {
    private let workbench: WorkbenchModel
    private let terminals: TerminalManager
    /// Make a folder the active workspace, opening it if helm does not have it yet — the same
    /// path a human takes through the workspace bar. Injected from `RootView` because
    /// activating spans the workspace list *and* the bench, which is the one kind of work
    /// `App/` is allowed to keep.
    private let activate: @MainActor (Workspace) -> Void

    init(
        workbench: WorkbenchModel, terminals: TerminalManager,
        activate: @escaping @MainActor (Workspace) -> Void
    ) {
        self.workbench = workbench
        self.terminals = terminals
        self.activate = activate
    }

    /// **The request's `cwd` becomes a workspace.** That is what makes the rest fall out for
    /// free: the pane's working directory is the workspace path, so the launch line needs no
    /// `cd`; the session is grouped under that path, so `BoardModel.hostedPids` marks it with
    /// nothing extra written for it (#36); and the operator gets a pane where the new agent
    /// is, which is what they would have made by hand.
    ///
    /// Switching the operator's view is the honest cost of a push channel, and #54 accepts it
    /// explicitly.
    ///
    /// **`spawnTerminal`, not `newTerminal`** — the two differ in exactly the two ways a
    /// request from outside must (#177). ⌘N's rule is "a tab where you are looking", and
    /// applied to a spool request that means a hidden tab on whatever had focus, canvas
    /// included. A spawn gets a pane of its own, and takes neither the selection nor the
    /// keyboard.
    func openTerminal(cwd: String) -> Result<UUID, SpoolRefusal> {
        let workspace = Workspace(path: cwd)
        if workbench.workspacePath != workspace.path {
            activate(workspace)
        }
        guard workbench.workspacePath == workspace.path else {
            return .failure(
                SpoolRefusal(
                    "helm could not make \(workspace.path.value) the active workspace"))
        }
        guard let session = workbench.spawnTerminal() else {
            return .failure(
                SpoolRefusal("helm could not open a terminal in \(workspace.path.value)"))
        }
        return .success(session.id)
    }

    func foregroundPid(of terminal: UUID) -> pid_t? {
        session(terminal)?.hostView.foregroundPid
    }

    /// Put the line in the pane and run it — two steps, because one does not work.
    ///
    /// **Measured, and it cost the first live run.** libghostty wraps *every* `sendText` in
    /// bracketed-paste markers whenever the shell has enabled mode 2004 — the wrapper says so
    /// in `UITerminalView+PublicSticky.swift`, and fish, zsh and bash all enable it. So a line
    /// ending in `\r` arrives as a **paste**: the shell puts it on the command line, including
    /// the newline, and waits. From outside that is indistinguishable from nothing having
    /// happened, which is exactly how it presented — a terminal opened, a shell running, and
    /// no agent ever.
    ///
    /// So the line is pasted and the Return is a separate binding action, which writes to the
    /// pty without the markers. It is the human gesture — paste, then Enter — and it is right
    /// in both directions: pasting is what makes an arbitrary prompt safe to put on a command
    /// line, and if the shell had *not* enabled mode 2004 the extra newline is a harmless empty
    /// Enter at a prompt.
    ///
    /// **Still no synthesised keystroke.** Nothing here goes near CGEvent, focus, or the
    /// display — it is an in-process call against the one surface helm created for this
    /// request, so it cannot land in whatever pane happens to hold the keyboard (#96).
    func send(_ line: String, to terminal: UUID) {
        guard let session = session(terminal) else { return }
        session.hostView.sendText(line)
        if !session.hostView.performBindingAction("text:\\n") {
            NSLog(
                "helm: spool could not submit the launch line — the pane holds it unrun. "
                    + "ghostty refused the `text` binding action on terminal %@",
                terminal.uuidString)
        }
    }

    private func session(_ id: UUID) -> TerminalSession? {
        terminals.sessions.first { $0.id == id }
    }
}
