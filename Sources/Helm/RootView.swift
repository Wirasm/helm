import SwiftUI

/// The two faces of helm. The terminal is the MAIN view — the driver (pi/claude/codex)
/// lives there and drives kild via its own skill/extension. The kild view is the
/// observe/steer surface. The pty must survive this toggle (once the terminal is real,
/// its process lives outside the view lifecycle — see docs/SPIKE.md).
enum MainView {
    case terminal
    case kild
}

struct RootView: View {
    @State private var current: MainView = .terminal

    var body: some View {
        ZStack {
            // Both stay mounted; visibility toggles. This is load-bearing: the terminal's
            // pty and the kild view's WS connection must not die on toggle. (The pty
            // would survive a full unmount too — GhosttyTerminal owns it app-level.)
            TerminalPane(isActive: current == .terminal)
                .opacity(current == .terminal ? 1 : 0)
                .allowsHitTesting(current == .terminal)
            KildView()
                .opacity(current == .kild ? 1 : 0)
                .allowsHitTesting(current == .kild)
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmToggleView)) { _ in
            current = current == .terminal ? .kild : .terminal
        }
    }
}

/// The real terminal: a GhosttyKit surface running the user's login shell, owned
/// app-level by `GhosttyTerminal.shared` so the pty outlives any view churn.
/// The old placeholder remains as the fallback, rendered only when ghostty init
/// failed (showing the error) or the shell exited.
struct TerminalPane: View {
    /// Whether this pane is RootView's frontmost face (drives focus + occlusion).
    var isActive: Bool

    @ObservedObject private var terminal = GhosttyTerminal.shared

    var body: some View {
        Group {
            switch terminal.status {
            case .starting, .running:
                GhosttyHostView(view: terminal.hostView, isActive: isActive)
            case let .failed(message):
                fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(title: "shell exited", detail: "Restart helm to start a new session.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding()
    }
}
