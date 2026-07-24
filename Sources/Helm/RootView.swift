import SwiftUI

/// The two faces of helm. The terminal workspace is the MAIN view — the driver
/// (pi/claude/codex) lives there and drives kild via its own skill/extension,
/// with an optional read-only artifact beside it. The kild view is the
/// observe/steer surface. Every pty must survive this toggle (the shells live
/// app-level in TerminalManager, outside the view lifecycle — see docs/SPIKE.md).
enum MainView {
    case terminal
    case kild
}

struct RootView: View {
    @State private var current: MainView = LaunchOptions.initialView == "kild" ? .kild : .terminal

    var body: some View {
        ZStack {
            // Both stay mounted; visibility toggles. This is load-bearing: the
            // terminals' ptys and the kild view's WS connection must not die on
            // toggle. (The ptys would survive a full unmount too — TerminalManager
            // owns them app-level.)
            TerminalWorkspace(isActive: current == .terminal)
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

/// The terminal face: tab strip over the selected terminal, with an optional
/// read-only artifact pane split off to the right ("driver in the terminal,
/// plan beside it"). The artifact pane is hidden until a file is opened.
struct TerminalWorkspace: View {
    /// Whether this face is RootView's frontmost (drives focus + occlusion).
    var isActive: Bool

    @ObservedObject private var manager = TerminalManager.shared
    @StateObject private var artifact = ArtifactPaneModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TerminalStrip(manager: manager) {
                    artifact.presentOpenPanel()
                }
                Divider()
                SessionPane(session: manager.selected, isActive: isActive)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if artifact.isOpen {
                ArtifactPane(model: artifact)
                    .frame(minWidth: 300, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let path = LaunchOptions.artifactPath {
                artifact.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        // ⌘N — new terminal (HelmApp's key monitor posts these; see HelmApp.swift).
        .onReceive(NotificationCenter.default.publisher(for: .helmNewTerminal)) { _ in
            manager.newTerminal()
        }
        // ⌘1–⌘9 — select terminal by tab position.
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectTerminal)) { note in
            if let index = note.object as? Int {
                manager.select(index: index)
            }
        }
        // ⌘O — open an artifact file beside the terminal.
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenArtifact)) { _ in
            artifact.presentOpenPanel()
        }
    }
}

/// The selected session's surface (or its fallback when init failed / the shell
/// exited). Observes the session so status flips re-render just this pane.
private struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    var isActive: Bool

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                // .id ties the representable to this session: a tab switch
                // dismantles it (unmounting the old NSView) and mounts the new
                // session's view — never creating or destroying the views
                // themselves, so every pty survives.
                GhosttyHostView(view: session.hostView, isActive: isActive)
                    .id(session.id)
            case let .failed(message):
                fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(
                    title: "shell exited",
                    detail: "Close this tab, or open a new terminal with ⌘N."
                )
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
