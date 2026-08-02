import SwiftUI

/// The terminal vertical's own root view: the tab strip over the selected
/// session, plus every terminal command the app shell used to forward.
///
/// These five subscriptions lived in `RootView` and made the shell file the
/// place every feature had to edit. Keeping a vertical's command handling
/// inside the vertical is what lets two features be built at once without
/// meeting in the same file.
struct TerminalWorkspace: View {
    @ObservedObject var manager: TerminalManager
    @ObservedObject var artifact: ArtifactPaneModel
    @Binding var showBrowser: Bool
    let workspaceRoot: String?
    /// Which face the pane is showing. One flag, one button (⌘T) — the terminal
    /// is always still there underneath either way.
    @State private var chat = false

    var body: some View {
        Group {
            if let session = manager.selected {
                VStack(spacing: 0) {
                    TerminalStrip(
                        manager: manager, artifact: artifact, showBrowser: $showBrowser,
                        workspaceRoot: workspaceRoot, chat: $chat)
                    Divider()
                    SessionPane(session: session, chat: chat)
                }
            } else {
                ContentUnavailableView(
                    "Open a workspace", systemImage: "folder",
                    description: Text("Choose a folder with ⌘⇧O to start a terminal."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmNewTerminal)) { _ in
            manager.newTerminal()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectTerminal)) { note in
            if let index = note.object as? Int { manager.select(index: index) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenArtifact)) { _ in
            showBrowser.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmAdjustFontSize)) { note in
            guard let raw = note.object as? Int, let step = FontSizeStep(rawValue: raw) else {
                return
            }
            manager.selected?.adjustFontSize(step)
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmJumpToPrompt)) { note in
            guard manager.selectedTerminalHasFocus, let offset = note.object as? Int else { return }
            manager.selected?.jumpToPrompt(by: offset)
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmToggleChat)) { _ in
            chat.toggle()
        }
    }
}

private struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    /// Draw the agent's writing over the terminal.
    ///
    /// **The terminal view stays mounted underneath.** One attached surface
    /// drives the ghostty runtime for every surface on it (`TerminalSession`'s
    /// header), so unmounting the only attached one would stall every pty in the
    /// app — including the ones this face is reading.
    let chat: Bool

    var body: some View {
        Group {
            switch session.status {
            case .starting, .running:
                ZStack {
                    GhosttyHostView(view: session.hostView).id(session.id)
                    // Keyed on the session: swapping tabs while reading must
                    // build a fresh model against the new terminal's agent, not
                    // reuse one pointed at the old pty.
                    if chat { ChatOverlay(session: session).id(session.id) }
                }
            case let .failed(message): fallback(title: "ghostty init failed", detail: message)
            case .exited:
                fallback(
                    title: "shell exited", detail: "Close this tab, or open a new terminal with ⌘N."
                )
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
            Color(nsColor: .textBackgroundColor))
    }
    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.secondary);
            Text(title).font(.title3);
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }.padding()
    }
}
