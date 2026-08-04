import SwiftUI

/// One terminal as a bench tenant, in whichever of its two faces the pane is showing.
///
/// This was `SessionPane` inside `TerminalWorkspace`, and it comes across unchanged. What
/// changed is only where `face` comes from: an associated value on the pane, read out of
/// the bench, instead of one `@State` flag shared by the whole terminal vertical. Two
/// terminals side by side can now show different faces — which is the point, because the
/// reason to read one agent's prose is usually to watch another agent's shell while you do.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    /// Only the placeholder needs this — it has to stand in for a grid ghostty is not
    /// drawing, at the opacity ghostty would have drawn it with, and that value differs by
    /// appearance. Follows `AppearanceOverride` because that is applied at the AppKit level.
    @Environment(\.colorScheme) private var colorScheme
    /// Draw the agent's writing over the terminal.
    ///
    /// **The terminal view stays mounted underneath.** One attached surface drives the
    /// ghostty runtime for every surface on it (`TerminalSession`'s header), so unmounting
    /// the only attached one would stall every pty in the app — including the ones this
    /// face is reading. Rendering the two faces as a `switch` is the obvious tidy-up and
    /// reintroduces exactly that stall; keep the `ZStack`.
    let face: TerminalFace
    /// Whether this pane is the bench's focused one — which is helm saying the keyboard
    /// belongs here. Read off the bench by `WorkbenchView` and passed straight through; which
    /// of this pane's two faces the keyboard then goes to is decided below, where the face is
    /// already a rendering concern.
    let holdsKeyboard: Bool

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                ZStack {
                    // **The grid claims the keyboard only on the terminal face.** It used to
                    // claim on both, deliberately, because the composer focused itself only on
                    // an offered prefill and a face-aware claim would have left *nothing*
                    // holding the keyboard on the chat face — #96 again, one pane over. The
                    // composer takes it for itself now (#152), so the two halves swap cleanly:
                    // ⌘T onto the chat face drops this claim without a fight, and ⌘T back is a
                    // `false → true` edge that hands the shell its keyboard again. Without the
                    // face here that edge never fires, and typing goes on reaching a composer
                    // the operator can no longer see.
                    GhosttyHostView(
                        view: session.hostView, holdsKeyboard: holdsKeyboard && face == .terminal
                    )
                    .id(session.id)
                    // Keyed on the session: swapping tabs while reading must
                    // build a fresh model against the new terminal's agent, not
                    // reuse one pointed at the old pty.
                    if face == .chat {
                        ChatOverlay(session: session, holdsKeyboard: holdsKeyboard)
                            .id(session.id)
                    }
                }
            case let .failed(message): fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(
                    title: "shell exited", detail: "Close this tab, or open a new terminal with ⌘N."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The frosted plane the grid composites against. It carries NO surface tint — the
        // grid draws that itself, at `TerminalSession.backgroundOpacity`, and tinting here
        // too would count it twice and cancel the translucency (see `TerminalBackdrop`).
        .background(TerminalBackdrop())
    }

    /// A pane with no grid — a dead shell, a failed config — still has to look like the
    /// terminal it replaced, so it lays the surface over the backdrop at the value ghostty
    /// would have drawn it with. Read from `TerminalSession` rather than repeated, so the
    /// two cannot drift and a dead shell never announces itself by changing weight.
    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.surface.opacity(
                TerminalSession.backgroundOpacity(in: colorScheme == .dark ? .dark : .light)))
    }
}
