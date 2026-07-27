import Inject
import SwiftUI

/// helm's permanent frame: workspace context bar above rooms, terminal, and dock.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var store = KildStore()
    @StateObject private var artifact = ArtifactPaneModel()
    @ObservedObject private var terminalManager = TerminalManager.shared
    @State private var showBrowser = false
    @AppStorage("helmDockWidth") private var dockWidth = 560.0
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceBar(store: store, select: switchWorkspace, open: openWorkspace, close: closeWorkspace)
            HSplitView {
                SidebarColumn(store: store)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420, maxHeight: .infinity)
                TerminalWorkspace(
                    manager: terminalManager,
                    artifact: artifact,
                    showBrowser: $showBrowser,
                    workspaceRoot: store.selectedWorkspaceRoot
                )
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if let room = store.selectedRoom {
                    dockPane {
                        RoomDetailView(
                            room: room,
                            engine: store.engine,
                            readOnly: store.tab == .history,
                            onPosted: { await store.load() },
                            draft: Binding(
                                get: { store.composerDraft(for: room.id) },
                                set: { store.setComposerDraft($0, for: room.id) }
                            )
                        ).id(room.id)
                    }
                } else if artifact.isOpen {
                    dockPane { ArtifactPane(model: artifact) }
                }
            }
        }
        .task {
            await store.load()
            activateSelectedWorkspace()
            if let path = LaunchOptions.artifactPath {
                artifact.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        .onReceive(refresh) { _ in Task { await store.load() } }
        .onChange(of: store.selection) { _, _ in persistCurrentContext() }
        .onChange(of: store.tab) { _, _ in persistCurrentContext() }
        .onChange(of: store.historyQuery) { _, _ in persistCurrentContext() }
        .onReceive(artifact.$document) { _ in persistCurrentContext() }
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectWorkspace)) { note in
            guard let index = note.object as? Int, store.workspaces.indices.contains(index) else { return }
            switchWorkspace(store.workspaces[index])
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmCycleWorkspace)) { note in
            guard let direction = note.object as? Int, !store.workspaces.isEmpty else { return }
            let current = store.selectedWorkspace.flatMap { store.workspaces.firstIndex(of: $0) } ?? 0
            let next = (current + direction + store.workspaces.count) % store.workspaces.count
            switchWorkspace(store.workspaces[next])
        }
        .enableInjection()
    }

    private func persistCurrentContext() {
        store.saveContext(terminalManager: terminalManager, artifact: artifact)
    }

    private func openWorkspace(_ workspace: Workspace) {
        store.saveContext(terminalManager: terminalManager, artifact: artifact)
        store.open(workspace)
        activateSelectedWorkspace()
    }

    private func closeWorkspace(_ workspace: Workspace) {
        store.saveContext(terminalManager: terminalManager, artifact: artifact)
        let wasSelected = store.selectedWorkspace == workspace
        terminalManager.closeWorkspace(workspace.path)
        store.close(workspace)
        if wasSelected, let replacement = store.workspaces.first {
            store.select(replacement)
            activateSelectedWorkspace()
        } else if wasSelected {
            terminalManager.deactivate()
            artifact.close()
        }
    }

    private func switchWorkspace(_ workspace: Workspace) {        guard store.selectedWorkspace != workspace else { return }
        store.saveContext(terminalManager: terminalManager, artifact: artifact)
        store.select(workspace)
        activateSelectedWorkspace()
    }

    private func activateSelectedWorkspace() {
        guard let workspace = store.selectedWorkspace else { return }
        let context = store.contexts[workspace.path] ?? WorkspaceContext()
        terminalManager.activate(workspacePath: workspace.path, selectedID: context.selectedTerminalID)
        if let path = context.openArtifactPath { artifact.open(URL(fileURLWithPath: path)) } else { artifact.close() }
    }

    private func dockPane(@ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(minWidth: 360, idealWidth: dockWidth, maxWidth: .infinity, maxHeight: .infinity)
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width) { _, width in dockWidth = width }
            })
            .onExitCommand { store.selection = nil }
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
                    TerminalStrip(manager: manager, artifact: artifact, showBrowser: $showBrowser, workspaceRoot: workspaceRoot)
                    Divider()
                    SessionPane(session: session)
                }
            } else {
                ContentUnavailableView("Open a workspace", systemImage: "folder", description: Text("Choose a folder with ⌘⇧O to start a terminal."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmNewTerminal)) { _ in manager.newTerminal() }
        .onReceive(NotificationCenter.default.publisher(for: .helmSelectTerminal)) { note in
            if let index = note.object as? Int { manager.select(index: index) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenArtifact)) { _ in showBrowser.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .helmAdjustFontSize)) { note in
            guard let raw = note.object as? Int, let step = FontSizeStep(rawValue: raw) else { return }
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
            case .exited: fallback(title: "shell exited", detail: "Close this tab, or open a new terminal with ⌘N.")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor))
    }
    private func fallback(title: String, detail: String) -> some View {
        VStack(spacing: 12) { Image(systemName: "terminal").font(.system(size: 44)).foregroundStyle(.secondary); Text(title).font(.title3); Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled) }.padding()
    }
}
