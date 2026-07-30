import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above a terminal, with the artifact pane as an
/// optional right dock.
///
/// The kild sidebar and its detail dock lived here until the backend was dropped. What is
/// left is the part that never depended on one — folders, terminals, and a renderer for
/// whatever file you point it at.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model = WorkspaceModel()
    @StateObject private var artifact = ArtifactPaneModel()
    @ObservedObject private var terminalManager = TerminalManager.shared
    @State private var showBrowser = false
    @AppStorage("helmDockWidth") private var dockWidth = 560.0

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(
                model: model, select: switchWorkspace, open: openWorkspace,
                close: closeWorkspace)
            HSplitView {
                TerminalWorkspace(
                    manager: terminalManager,
                    artifact: artifact,
                    showBrowser: $showBrowser,
                    workspaceRoot: model.selectedWorkspaceRoot
                )
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if artifact.isOpen {
                    ArtifactPane(model: artifact)
                        .frame(
                            minWidth: 360, idealWidth: dockWidth, maxWidth: .infinity,
                            maxHeight: .infinity
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.onChange(of: geo.size.width) { _, width in
                                    dockWidth = width
                                }
                            }
                        )
                        .onExitCommand { artifact.close() }
                }
            }
        }
        .task {
            activateSelectedWorkspace()
            if let path = LaunchOptions.artifactPath {
                artifact.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        .onReceive(artifact.$document) { _ in persistCurrentContext() }
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectWorkspace)) { note in
            guard let index = note.object as? Int, model.workspaces.indices.contains(index) else {
                return
            }
            switchWorkspace(model.workspaces[index])
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmCycleWorkspace)) { note in
            guard let direction = note.object as? Int, !model.workspaces.isEmpty else { return }
            let current =
                model.selectedWorkspace.flatMap { model.workspaces.firstIndex(of: $0) } ?? 0
            let next = (current + direction + model.workspaces.count) % model.workspaces.count
            switchWorkspace(model.workspaces[next])
        }
        .enableInjection()
    }

    private func persistCurrentContext() {
        model.saveContext(terminalManager: terminalManager, artifact: artifact)
    }

    private func openWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        model.open(workspace)
        activateSelectedWorkspace()
    }

    private func closeWorkspace(_ workspace: Workspace) {
        persistCurrentContext()
        let wasSelected = model.selectedWorkspace == workspace
        terminalManager.closeWorkspace(workspace.path)
        model.close(workspace)
        if wasSelected, let replacement = model.workspaces.first {
            model.select(replacement)
            activateSelectedWorkspace()
        } else if wasSelected {
            terminalManager.deactivate()
            artifact.close()
        }
    }

    private func switchWorkspace(_ workspace: Workspace) {
        guard model.selectedWorkspace != workspace else { return }
        persistCurrentContext()
        model.select(workspace)
        activateSelectedWorkspace()
    }

    private func activateSelectedWorkspace() {
        guard let workspace = model.selectedWorkspace else { return }
        let context = model.contexts[workspace.path] ?? WorkspaceContext()
        terminalManager.activate(
            workspacePath: workspace.path, selectedID: context.selectedTerminalID)
        if let path = context.openArtifactPath {
            artifact.open(URL(fileURLWithPath: path))
        } else {
            artifact.close()
        }
    }
}

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
