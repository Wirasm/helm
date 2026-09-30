import Foundation
import HelmWire
import SwiftUI

/// Every worktree on the machine as a `SurfaceKind` (#382): a `WorktreesModel` per pane, drawn
/// by `WorktreesDrawerView`. It lives in the `worktrees` drawer (⌘⇧G) on the right, where the
/// rail it replaced used to sit.
@MainActor
final class WorktreesPaneKind: SurfaceKind {
    /// Weak for `SessionsPaneKind`'s reason: the registration can outlive a closed window.
    private weak var workbench: WorkbenchModel?
    private weak var terminals: TerminalManager?

    init(workbench: WorkbenchModel, terminals: TerminalManager) {
        self.workbench = workbench
        self.terminals = terminals
    }

    let kind: Pane.Content.Kind = .worktrees

    func make(for pane: Pane, in workspace: WorkspacePath?) -> WorktreesDrawer? {
        guard let workbench else { return nil }
        return WorktreesDrawer(
            model: {
                let host = BenchdHost(client: workbench.client)
                return WorktreesModel(
                    worktreeClient: WorktreeCLI(host: host),
                    discover: { try await host.repositories(workspaces: $0) })
            }(),
            document: { [weak workbench] in workbench?.document },
            openWorkspace: { [weak workbench] path in
                workbench?.send(.workspaceOpen(path: path), by: .operatorGesture)
            },
            runInNewTerminal: { [weak workbench, weak terminals] line in
                guard let workbench, let terminals else { return "helm is closing" }
                return await NewTerminalLine.run(line, workbench: workbench, terminals: terminals)
            })
    }

    func view(of drawer: WorktreesDrawer, in slot: SurfaceSlot) -> AnyView {
        AnyView(WorktreesDrawerView(drawer: drawer, holdsKeyboard: slot.holdsKeyboard))
    }

    func tab(of drawer: WorktreesDrawer, in slot: SurfaceSlot) -> AnyView {
        AnyView(
            PaneTab(
                title: slot.pane.name.text ?? "worktrees", truncation: .tail,
                closeHelp: "Close the worktree list", slot: slot
            ) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
            })
    }

    func close(_ drawer: WorktreesDrawer) {}
}

/// One Worktrees pane's live object: the model; benchd's document, which says which
/// repositories the bench's workspaces are in and which panes work where; and the two ways to
/// open a worktree, both the operator's gestures.
@MainActor
final class WorktreesDrawer {
    let model: WorktreesModel
    let document: @MainActor () -> BenchDocument?
    /// `workspace/open` for the worktree's folder.
    let openWorkspace: @MainActor (String) -> Void
    /// Opens a terminal on the bench and runs one line in it; answers why it could not.
    let runInNewTerminal: @MainActor (String) async -> String?

    init(
        model: WorktreesModel, document: @escaping @MainActor () -> BenchDocument?,
        openWorkspace: @escaping @MainActor (String) -> Void,
        runInNewTerminal: @escaping @MainActor (String) async -> String?
    ) {
        self.model = model
        self.document = document
        self.openWorkspace = openWorkspace
        self.runInNewTerminal = runInNewTerminal
    }

    /// The line a new terminal runs to stand in `path`.
    nonisolated static func changeDirectoryLine(to path: String) -> String {
        "cd '" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    var workspaces: [String] { document()?.workspaces.map(\.path) ?? [] }
}
