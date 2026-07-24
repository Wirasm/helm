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
            // pty and the kild view's WS connection must not die on toggle.
            TerminalPane()
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

/// Placeholder until GhosttyKit is built and embedded (scripts/build-ghosttykit.sh).
/// The spike's exit criterion: this pane hosts a real libghostty surface running the
/// user's shell, and survives the ⌘T toggle without losing the session.
struct TerminalPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("libghostty lands here")
                .font(.title3)
            Text("scripts/build-ghosttykit.sh · docs/SPIKE.md\n⌘T toggles to the kild view")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
