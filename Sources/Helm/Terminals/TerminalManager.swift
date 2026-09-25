import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalManager

/// App-level owner of the terminal sessions' **lifecycle** — which workspace's shells exist,
/// restoring them, making new ones — and of the app's one `SurfaceRegistry`, which is where the
/// sessions themselves are kept, beside every other kind of pane's live object (PR 3a of #354).
/// Selection belongs to the slot that shows a session, under a bench.
///
/// **Why the registry hangs off this type.** Every caller that needs a terminal already holds a
/// `TerminalManager` (`.shared` in the app, an isolated one in each test), so the registry comes
/// with it and nothing's construction changed. It is the terminal *kind* that lives here
/// (`TerminalPaneKind`); canvases and browsers register theirs from `WorkbenchModel`. M5b moves
/// ptys to benchd and is where this type shrinks to what is left.
///
/// It used to own both. `selectedID` was one id per workspace, which worked while helm
/// mounted exactly one terminal; under a bench N slots each have their own selected pane
/// and all of them are on screen at once, so a single id could not express the state at
/// all. It is `Slot.selected` now, and a shadow copy kept "in sync" here would be the
/// same module wearing two filenames (`AGENTS.md`). Deleted rather than deprecated.
///
/// Invariants:
/// - Sessions are never removed by this type on its own account: `close` does what it is
///   told, and refusing the bench's last pane is `Workbench.canClose`'s rule. A workspace
///   whose panes are all canvases legitimately has no terminal left.
/// - Sessions (and their NSViews + ptys) live exactly as long as their tab:
///   dropping the last reference here deallocs the view → coordinator →
///   surface, which is what actually kills the shell.
/// - Every session shares this manager's ONE `TerminalController` — one
///   `ghostty_app_t` for the whole app, N surfaces on it (see the
///   TerminalSession header). It is owned here rather than globally so tests
///   can build isolated managers without leaking runtime state between them.
@MainActor
final class TerminalManager: ObservableObject {
    static let shared = TerminalManager()

    /// Every live pane object of every kind. Sessions are the terminal entries in it.
    let surfaces: SurfaceRegistry

    /// Every workspace's sessions, in creation order. Switching a workspace only changes which
    /// subset is mounted; it never releases one.
    var sessions: [TerminalSession] { surfaces.models(TerminalSession.self) }
    @Published private(set) var activeWorkspacePath: WorkspacePath?

    /// Re-publishes the registry's changes as this manager's, so everything that observed
    /// `sessions` changing (the snapshot, workspace persistence) still sees them.
    private var forwarding: AnyCancellable?

    /// The single ghostty runtime every session's surface is created on.
    let controller: TerminalController

    private var nextOrdinal = 1

    /// What each new session's surface is wired to. A factory rather than a value because
    /// an in-memory backend carries per-session state; see `TerminalSession.init`.
    private let backend: @MainActor () -> TerminalSessionBackend

    /// Internal (not private) so tests can build isolated managers; the app
    /// itself only ever uses `.shared`, which is `.exec` — a real login shell.
    init(
        backend: @escaping @MainActor () -> TerminalSessionBackend = { .exec },
        surfaces: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.backend = backend
        self.surfaces = surfaces
        controller = TerminalSession.makeController()
        surfaces.register(TerminalPaneKind(manager: self))
        forwarding = surfaces.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // No pty is created until a workspace is first visited. This bounds
        // startup cost to the active context rather than all remembered folders.
    }

    func sessions(for workspacePath: WorkspacePath) -> [TerminalSession] {
        surfaces.models(TerminalSession.self, in: workspacePath)
    }

    /// Makes a workspace active, lazily rebuilding its tab row on first visit.
    /// Existing sessions are merely parked (their retained NSViews and ptys survive).
    ///
    /// `restoring` carries the ids persisted for this workspace. On the first visit
    /// after a relaunch they name terminals whose ptys died with the old process, so
    /// the row is rebuilt under those same ids — and **the shells still come back empty**.
    ///
    /// That last part did not change with #63, and it is worth being exact about what did.
    /// This type still starts nothing but a login shell: helm attaches to agents, it never
    /// owns their launch. What #63 added is one level up — a restored *pane* whose persisted
    /// record names an agent shows an **offer** to resume it (`AgentResumeBar`), and only the
    /// operator accepting one ever puts a `--resume` line in a pty. Nothing here re-runs
    /// anything, and a helm nobody clicks in behaves exactly as it always has.
    ///
    /// Restore stays lazy on purpose. `init` creates no pty until a workspace is
    /// visited, which bounds startup to the active context rather than every
    /// remembered folder — eager restore would spawn each one's shells at launch.
    func activate(workspacePath: WorkspacePath, restoring restorable: [UUID] = []) {
        activeWorkspacePath = workspacePath
        if sessions(for: workspacePath).isEmpty {
            restore(restorable, in: workspacePath)
        }
    }

    /// Rebuilds a workspace's tab row from persisted ids, or opens one fresh shell
    /// when there is nothing to restore — which is also the never-visited case, so
    /// a first-run workspace still behaves exactly as it always has.
    private func restore(_ ids: [UUID], in workspacePath: WorkspacePath) {
        guard !ids.isEmpty else {
            newTerminal(in: workspacePath)
            return
        }
        for id in ids {
            let session = TerminalSession(
                id: id, ordinal: nextOrdinal, workspacePath: workspacePath,
                controller: controller, backend: backend())
            nextOrdinal += 1
            session.manager = self
            surfaces.adopt(session, as: id, kind: .terminal, in: workspacePath)
        }
    }

    func deactivate() {
        activeWorkspacePath = nil
    }

    /// Closing a workspace is an explicit teardown, unlike switching: every pane object it
    /// owned goes — its sessions, so their retained NSViews release their ptys, and its
    /// canvases and browser views, each through its own kind's `close`.
    func closeWorkspace(_ workspacePath: WorkspacePath) {
        surfaces.closeWorkspace(workspacePath)
        if activeWorkspacePath == workspacePath { deactivate() }
    }

    /// Whether ANY terminal's view is (or contains) the key window's first responder —
    /// the focus gate for terminal-only shortcuts (⌘↑/⌘↓ prompt jump). Needed since the
    /// one-surface re-layout: the terminal is always frontmost now, so "the terminal face
    /// is active" no longer implies the terminal has keyboard focus.
    ///
    /// This is *simpler* than the `selectedTerminalHasFocus` it replaces, and that is the
    /// tell: "is a terminal focused" never needed a selection to answer. Under a bench
    /// several terminals are on screen, and the shortcut belongs to whichever one the
    /// operator is typing into.
    var anyTerminalHasFocus: Bool {
        guard let window = NSApp.keyWindow, let responder = window.firstResponder as? NSView
        else { return false }
        return sessions.contains { session in
            let view = session.hostView
            return responder === view || responder.isDescendant(of: view)
        }
    }

    /// A fresh login shell in a workspace. Returns it, because the caller is the bench and
    /// the bench needs the id to build the pane that will show it.
    @discardableResult
    func newTerminal(in workspacePath: WorkspacePath) -> TerminalSession {
        let session = TerminalSession(
            ordinal: nextOrdinal, workspacePath: workspacePath, controller: controller,
            backend: backend())
        nextOrdinal += 1
        session.manager = self
        surfaces.adopt(session, as: session.id, kind: .terminal, in: workspacePath)
        activeWorkspacePath = workspacePath
        return session
    }

    /// Closes the tab AND its shell: removing the session drops the last strong
    /// reference (once SwiftUI unmounts the view), deallocating view →
    /// coordinator → surface → pty.
    ///
    /// It no longer refuses the workspace's last terminal. That rule did not disappear —
    /// it generalised, to `Workbench.canClose`, which refuses the bench's last *pane*. A
    /// workspace showing one terminal and one canvas may legitimately close the terminal.
    func close(_ session: TerminalSession) {
        surfaces.close(session.id)
    }
}
