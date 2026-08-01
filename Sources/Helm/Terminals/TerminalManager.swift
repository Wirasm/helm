import AppKit
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalManager

/// App-level owner of the ordered terminal sessions and the tab selection.
///
/// Invariants:
/// - `sessions` is never empty: init creates the first shell and `close`
///   refuses to remove the last one (the tab strip disables that button too).
/// - `selectedID` always names a live session; closing the selected tab moves
///   selection to its nearest surviving neighbor.
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
    @Published private(set) var selectedID: TerminalSession.ID?
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
    func activate(
        workspacePath: String, selectedID preferredID: UUID? = nil,
        restoring restorable: [UUID] = []
    ) {
        activeWorkspacePath = workspacePath
        if sessions(for: workspacePath).isEmpty {
            restore(restorable, in: workspacePath)
        }
        let workspaceSessions = sessions(for: workspacePath)
        if let preferredID, let preferred = workspaceSessions.first(where: { $0.id == preferredID })
        {
            setSelected(preferred)
        } else if let selectedID, workspaceSessions.contains(where: { $0.id == selectedID }) {
            // Keep this workspace's selection when returning to it.
        } else if let first = workspaceSessions.first {
            setSelected(first)
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
        selectedID = nil
    }

    /// Closing a workspace is an explicit tab teardown, unlike switching: drop
    /// every session it owns so their retained NSViews release their ptys.
    func closeWorkspace(_ workspacePath: String) {
        sessions.removeAll { $0.workspacePath == workspacePath }
        if activeWorkspacePath == workspacePath { deactivate() }
    }

    var selected: TerminalSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    /// The last terminal in the active workspace cannot be closed.
    var canClose: Bool {
        guard let activeWorkspacePath else { return false }
        return sessions(for: activeWorkspacePath).count > 1
    }

    /// Whether the selected terminal's view is (or contains) the key window's
    /// first responder — the focus gate for terminal-only shortcuts (⌘↑/⌘↓
    /// prompt jump). Needed since the one-surface re-layout: the terminal is
    /// always frontmost now, so "the terminal face is active" no longer
    /// implies the terminal has keyboard focus.
    var selectedTerminalHasFocus: Bool {
        guard let selected else { return false }
        let view = selected.hostView
        guard let window = view.window, window.isKeyWindow,
            let responder = window.firstResponder as? NSView
        else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    /// ⌘N / the strip's + button: a fresh login shell in the active workspace.
    func newTerminal() {
        guard let activeWorkspacePath else { return }
        newTerminal(in: activeWorkspacePath)
    }

    func newTerminal(in workspacePath: String) {
        let session = TerminalSession(
            ordinal: nextOrdinal, workspacePath: workspacePath, controller: controller)
        nextOrdinal += 1
        session.manager = self
        sessions.append(session)
        activeWorkspacePath = workspacePath
        setSelected(session)
    }

    func select(_ session: TerminalSession) {
        guard session.workspacePath == activeWorkspacePath,
            sessions.contains(where: { $0.id == session.id })
        else { return }
        setSelected(session)
    }

    /// ⌘1–⌘9: select by 0-based tab position; out-of-range is a no-op.
    func select(index: Int) {
        guard let activeWorkspacePath else { return }
        let workspaceSessions = sessions(for: activeWorkspacePath)
        guard workspaceSessions.indices.contains(index) else { return }
        setSelected(workspaceSessions[index])
    }

    /// Selection always clears the incoming tab's bell and finished-command
    /// marks — looking at a terminal acknowledges its attention state.
    private func setSelected(_ session: TerminalSession) {
        selectedID = session.id
        session.acknowledgeAttention()
    }

    /// Closes the tab AND its shell: removing the session drops the last strong
    /// reference (once SwiftUI unmounts the view), deallocating view →
    /// coordinator → surface → pty. Refuses on the last remaining terminal.
    func close(_ session: TerminalSession) {
        guard session.workspacePath == activeWorkspacePath,
            canClose,
            let index = sessions.firstIndex(where: { $0.id == session.id })
        else { return }
        let workspaceSessions = sessions(for: session.workspacePath)
        let workspaceIndex = workspaceSessions.firstIndex(where: { $0.id == session.id }) ?? 0
        sessions.remove(at: index)
        if selectedID == session.id {
            let survivors = sessions(for: session.workspacePath)
            setSelected(survivors[min(workspaceIndex, survivors.count - 1)])
        }
    }
}
