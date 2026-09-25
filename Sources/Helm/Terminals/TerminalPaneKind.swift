import SwiftUI

/// The terminal as a `SurfaceKind`: a `TerminalSession`, drawn by `TerminalPaneView`.
///
/// **It never makes a session on demand.** A terminal's session is made first, by
/// `TerminalManager` (a new shell, or a restored one), and its id becomes the pane's — so a
/// terminal pane with no session is one whose shell was closed under it, and it renders nothing
/// rather than quietly starting another.
@MainActor
final class TerminalPaneKind: SurfaceKind {
    /// Unowned: the manager owns the registry, which owns this kind.
    private unowned let manager: TerminalManager

    init(manager: TerminalManager) {
        self.manager = manager
    }

    let kind: Pane.Content.Kind = .terminal

    /// A pty is the work itself, and a shell in a parked workspace keeps running.
    let survivesUnmount = true

    func make(for pane: Pane, in workspace: WorkspacePath?) -> TerminalSession? { nil }

    func view(of session: TerminalSession, in slot: SurfaceSlot) -> AnyView {
        AnyView(TerminalPaneView(session: session, holdsKeyboard: slot.holdsKeyboard))
    }

    func tab(of session: TerminalSession, in slot: SurfaceSlot) -> AnyView {
        AnyView(TerminalTab(session: session, slot: slot))
    }

    /// Dropping the registry's reference is what closes it: the view, its coordinator, the
    /// surface and the pty go with the last strong reference.
    func close(_ session: TerminalSession) {}
}
