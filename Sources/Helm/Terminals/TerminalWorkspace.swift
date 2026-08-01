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

    var body: some View {
        Group {
            if let session = manager.selected {
                VStack(spacing: 0) {
                    TerminalStrip(
                        manager: manager, artifact: artifact, showBrowser: $showBrowser,
                        workspaceRoot: workspaceRoot)
                    Divider()
                    SessionPane(session: session)
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
    }
}

private struct SessionPane: View {
    @ObservedObject var session: TerminalSession
    var body: some View {
        Group {
            switch session.status {
            case .starting, .running: GhosttyHostView(view: session.hostView).id(session.id)
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
