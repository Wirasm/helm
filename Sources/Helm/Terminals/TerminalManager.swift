import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalManager

/// App-level owner of the ordered terminal sessions. **Ownership only** — selection
/// belongs to the slot that shows a session, under a bench.
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

    /// Flat app-level ownership of every workspace's sessions. Switching a
    /// workspace only changes which subset is mounted; it never releases one.
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var activeWorkspacePath: String?

    /// The single ghostty runtime every session's surface is created on.
    let controller: TerminalController

    private var nextOrdinal = 1

    /// Internal (not private) so tests can build isolated managers; the app
    /// itself only ever uses `.shared`.
    init() {
        controller = TerminalSession.makeController()
        // No pty is created until a workspace is first visited. This bounds
        // startup cost to the active context rather than all remembered folders.
    }

    func sessions(for workspacePath: String) -> [TerminalSession] {
        sessions.filter { $0.workspacePath == workspacePath }
    }

    /// Makes a workspace active, lazily rebuilding its tab row on first visit.
    /// Existing sessions are merely parked (their retained NSViews and ptys survive).
    ///
    /// `restoring` carries the ids persisted for this workspace. On the first visit
    /// after a relaunch they name terminals whose ptys died with the old process, so
    /// the row is rebuilt under those same ids — the shells come back **empty**, and
    /// an agent is a `cls --resume` away. helm deliberately does not re-run it:
    /// helm attaches to agents, it never owns their launch.
    ///
    /// Restore stays lazy on purpose. `init` creates no pty until a workspace is
    /// visited, which bounds startup to the active context rather than every
    /// remembered folder — eager restore would spawn each one's shells at launch.
    func activate(workspacePath: String, restoring restorable: [UUID] = []) {
        activeWorkspacePath = workspacePath
        if sessions(for: workspacePath).isEmpty {
            restore(restorable, in: workspacePath)
        }
    }

    /// Rebuilds a workspace's tab row from persisted ids, or opens one fresh shell
    /// when there is nothing to restore — which is also the never-visited case, so
    /// a first-run workspace still behaves exactly as it always has.
    private func restore(_ ids: [UUID], in workspacePath: String) {
        guard !ids.isEmpty else {
            newTerminal(in: workspacePath)
            return
        }
        for id in ids {
            let session = TerminalSession(
                id: id, ordinal: nextOrdinal, workspacePath: workspacePath, controller: controller)
            nextOrdinal += 1
            session.manager = self
            sessions.append(session)
        }
    }

    func deactivate() {
        activeWorkspacePath = nil
    }

    /// Closing a workspace is an explicit tab teardown, unlike switching: drop
    /// every session it owns so their retained NSViews release their ptys.
    func closeWorkspace(_ workspacePath: String) {
        sessions.removeAll { $0.workspacePath == workspacePath }
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
    func newTerminal(in workspacePath: String) -> TerminalSession {
        let session = TerminalSession(
            ordinal: nextOrdinal, workspacePath: workspacePath, controller: controller)
        nextOrdinal += 1
        session.manager = self
        sessions.append(session)
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
        sessions.removeAll { $0.id == session.id }
    }
}
