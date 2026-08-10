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
    /// **The pane is named before it is returned (#313).** `SpoolModel` derived the name from the
    /// request it holds; this only applies it, so a spool-spawned tab reads `claude · <tree>`
    /// rather than whatever OSC title the agent's first message produces — which since #93 is a
    /// pointer at a file.
    func openTerminal(cwd: String, named: PaneName) -> Result<UUID, SpoolRefusal> {
        let workspace = Workspace(path: cwd)
        if workbench.workspacePath != workspace.path {
            activate(workspace)
        }
        // **#85's question is resolved by name, not by noticing that `bench == nil`.** A
        // workspace can now be the mounted one with no bench built, because the mount stopped to
        // ask the operator whether to restore what was saved — and this is the case where they
        // are demonstrably *at* the pane, since the question is on their screen. Reaching it
        // through the general "was anything mounted?" branch answered that question as a side
        // effect of a condition that used to mean something else. `mountWithoutAsking` is the
        // named act, and its header argues why a spawn resolves the question rather than
        // waiting behind it. `activate` above is the non-asking open, so a *different*
        // workspace never leaves one behind for this to find.
        workbench.mountWithoutAsking()
        guard workbench.workspacePath == workspace.path else {
            return .failure(
                SpoolRefusal(
                    "helm could not make \(workspace.path.value) the active workspace"))
        }
        guard let session = workbench.spawnTerminal() else {
            return .failure(
                SpoolRefusal("helm could not open a terminal in \(workspace.path.value)"))
        }
        workbench.name(session.id, to: named)
        return .success(session.id)
    }

    func foregroundPid(of terminal: UUID) -> pid_t? {
        session(terminal)?.hostView.foregroundPid
    }

    /// Put the line in the pane and run it.
    ///
    /// **The paste-then-Return dance is `TerminalLaunchLine`'s**, and it moved there when #63
    /// gave it a second caller: a resume line goes into a pane the same way a launch line
    /// does, and libghostty's bracketed-paste behaviour — the measurement that cost the first
    /// live spool run — is a fact about the surface rather than about the spool. Two spellings
    /// of it would be one measurement and two places to forget it.
    func send(_ line: String, to terminal: UUID) {
        guard let session = session(terminal) else { return }
        TerminalLaunchLine.send(line, to: session)
    }

    private func session(_ id: UUID) -> TerminalSession? {
        terminals.sessions.first { $0.id == id }
    }
}
