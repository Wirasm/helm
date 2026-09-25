import SwiftUI

/// One terminal as a bench tenant.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    /// Only the placeholder needs this — it has to stand in for a grid ghostty is not
    /// drawing, at the opacity ghostty would have drawn it with, and that value differs by
    /// appearance. Follows `AppearanceOverride` because that is applied at the AppKit level.
    @Environment(\.colorScheme) private var colorScheme
    /// Whether this pane is the bench's focused one — which is helm saying the keyboard
    /// belongs here. Read off the bench by `WorkbenchView` and passed straight through.
    let holdsKeyboard: Bool

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                GhosttyHostView(view: session.hostView, holdsKeyboard: holdsKeyboard)
                    .id(session.id)
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
            Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(Color.textMuted)
            Text(title).font(.title3)
            Text(detail).font(.callout).foregroundStyle(Color.textMuted).multilineTextAlignment(
                .center
            )
            .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color.surface.opacity(
                TerminalSession.backgroundOpacity(in: colorScheme == .dark ? .dark : .light)))
    }
}
