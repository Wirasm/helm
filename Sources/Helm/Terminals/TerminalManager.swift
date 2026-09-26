import AppKit
import Combine
import GhosttyTerminal
import SwiftUI

// MARK: - TerminalManager

/// App-level owner of the terminal sessions' **lifecycle** — a shell for every terminal pane in
/// benchd's document (`adopt`) — and of the app's one `SurfaceRegistry`, which is where the
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
/// - Sessions are never removed by this type on its own account: a session goes when its pane
///   leaves the document (`WorkbenchModel.apply`), and refusing the bench's last pane is
///   benchd's rule. A workspace whose panes are all canvases legitimately has no terminal left.
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

    /// The bench a session's ⌘-clicked link goes to, as a verb. Set by the
    /// `WorkbenchModel` built on this manager; weak because that model holds this manager.
    weak var bench: WorkbenchModel?

    /// The single ghostty runtime every session's surface is created on.
    let controller: TerminalController

    private var nextOrdinal = 1

    /// What each new session's surface runs instead of the login shell. A factory rather than
    /// a value because a test gives every session its own recorder; see `TerminalSession.init`.
    private let command: @MainActor () -> String?

    /// Internal (not private) so tests can build isolated managers; the app
    /// itself only ever uses `.shared`, whose command is `nil` — a real login shell.
    init(
        command: @escaping @MainActor () -> String? = { nil },
        surfaces: SurfaceRegistry = SurfaceRegistry()
    ) {
        self.command = command
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

    /// A login shell under each of `ids`. After a relaunch they name terminals whose ptys died
    /// with the old process, so the row is rebuilt under those same ids — and **the shells come
    /// back empty**. This type starts nothing but a login shell: helm attaches to agents, it
    /// never owns their launch. A restored *pane* whose record names an agent shows an **offer**
    /// to resume it (`AgentResumeBar`), and only the operator accepting one puts a `--resume`
    /// line in a pty.
    ///
    /// The exception is a pane that shows a benchd session (M3): `attaching` names the command
    /// its pty runs instead, `bench attach <session>`, so the pane is the agent benchd runs.
    private func restore(
        _ ids: [UUID], in workspacePath: WorkspacePath, attaching: [UUID: String] = [:]
    ) {
        for id in ids {
            let session = TerminalSession(
                id: id, ordinal: nextOrdinal, workspacePath: workspacePath,
                controller: controller, command: attaching[id] ?? command())
            nextOrdinal += 1
            session.manager = self
            surfaces.adopt(session, as: id, kind: .terminal, in: workspacePath)
        }
    }

    func deactivate() {
        activeWorkspacePath = nil
    }

    /// The workspace on screen, `path`, and a session for every terminal pane in `ids` that has
    /// none — benchd's document naming terminals this helm has not started (#354). The pane id is
    /// the session id, as on restore, and like a restore each comes back as a fresh login shell.
    /// Only the workspace on screen is adopted: its shells start when it is first shown, which
    /// bounds startup to what is drawn.
    ///
    /// `attaching` is the command for each pane that shows a benchd session
    /// (`BenchDocument.Bench.attachCommands`): `bench attach <session>`, so the pane is the agent benchd
    /// runs. Every other pane gets a login shell.
    func adopt(terminals ids: [UUID], in path: WorkspacePath, attaching: [UUID: String] = [:]) {
        activeWorkspacePath = path
        let missing = ids.filter { surfaces.existing($0, as: TerminalSession.self) == nil }
        guard !missing.isEmpty else { return }
        restore(missing, in: path, attaching: attaching)
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
}
