import Inject
import SwiftUI

/// helm's permanent frame: the workspace bar above a terminal, with the canvas as an
/// optional right dock.
///
/// **Composition only.** Each vertical owns its own commands — terminal shortcuts live in
/// `TerminalWorkspace`, opening a canvas lives on `ArtifactPaneModel` — so what is left
/// here is the work that genuinely spans them. Every subscription below touches two or
/// more verticals at once: persisting a workspace's context needs the workspace, its
/// terminals and its open canvas together, and switching workspaces has to move all
/// three. Anything that can name a single vertical belongs in that vertical's slice,
/// not in this file.
struct RootView: View {
    @ObserveInjection private var inject
    @StateObject private var model = WorkspaceModel()
    @StateObject private var artifact = ArtifactPaneModel()
    @ObservedObject private var terminalManager = TerminalManager.shared
    @State private var showBrowser = false

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
                    CanvasDock(model: artifact)
                }
            }
        }
        .task {
            activateSelectedWorkspace()
            if let path = LaunchOptions.artifactPath {
                artifact.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            }
        }
        .onReceive(artifact.$source) { _ in persistCurrentContext() }
        // Opening or closing a terminal, and switching tabs, are what a relaunch has to
        // rebuild. Without this the context is only written on workspace switch, so
        // quitting from the workspace you were working in saves a stale tab row — the
        // one case restore most needs to get right.
        //
        // This was two `.onReceive(terminalManager.$sessions.dropFirst())` subscriptions
        // and it silently lost writes: measured live, three open terminals persisted as
        // one. Two faults, both invisible from the code alone —
        //
        // 1. `$sessions.dropFirst()` builds a NEW publisher on every body evaluation, so
        //    `onReceive` resubscribes and `dropFirst` eats the next real event each time.
        //    (`artifact.$source` above survives precisely because it has no operator: the
        //    projected publisher is one stored instance, so its identity is stable.)
        // 2. `@Published` fires in `willSet`, so a handler that re-reads the manager sees
        //    the value it had *before* the change.
        //
        // `.task` runs once for the view's lifetime rather than per render, which fixes
        // identity; awaiting the next iteration puts the read after the mutation lands,
        // which fixes staleness. `objectWillChange` needs no `dropFirst` — unlike a
        // `@Published` projection it does not replay a current value on subscribe, and
        // that replay is what made `dropFirst` look necessary in the first place.
        .task {
            for await _ in terminalManager.objectWillChange.values {
                await Task.yield()
                persistCurrentContext()
            }
        }
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
            workspacePath: workspace.path, selectedID: context.selectedTerminalID,
            restoring: context.terminalSessionIDs)
        if let path = context.openArtifactPath {
            artifact.open(URL(fileURLWithPath: path))
        } else {
            artifact.close()
        }
    }
}
