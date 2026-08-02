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
    /// Draw the agent's writing over the terminal.
    ///
    /// **The terminal view stays mounted underneath.** One attached surface drives the
    /// ghostty runtime for every surface on it (`TerminalSession`'s header), so unmounting
    /// the only attached one would stall every pty in the app — including the ones this
    /// face is reading. Rendering the two faces as a `switch` is the obvious tidy-up and
    /// reintroduces exactly that stall; keep the `ZStack`.
    let face: TerminalFace

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                ZStack {
                    GhosttyHostView(view: session.hostView).id(session.id)
                    // Keyed on the session: swapping tabs while reading must
                    // build a fresh model against the new terminal's agent, not
                    // reuse one pointed at the old pty.
                    if face == .chat { ChatOverlay(session: session).id(session.id) }
                }
            case let .failed(message): fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(
                    title: "shell exited", detail: "Close this tab, or open a new terminal with ⌘N."
                )
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.surface)
    }

    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.title3)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }.padding()
    }
}
