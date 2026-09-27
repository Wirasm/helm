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

    init(workbench: WorkbenchModel) {
        self.workbench = workbench
    }

    let kind: Pane.Content.Kind = .worktrees

    func make(for pane: Pane, in workspace: WorkspacePath?) -> WorktreesDrawer? {
        guard let workbench else { return nil }
        return WorktreesDrawer(
            model: WorktreesModel(),
            document: { [weak workbench] in workbench?.document })
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

/// One Worktrees pane's live object: the model, and benchd's document, which says which
/// repositories the bench's workspaces are in and which panes work where.
@MainActor
final class WorktreesDrawer {
    let model: WorktreesModel
    let document: @MainActor () -> BenchDocument?

    init(model: WorktreesModel, document: @escaping @MainActor () -> BenchDocument?) {
        self.model = model
        self.document = document
    }

    var workspaces: [String] { document()?.workspaces.map(\.path) ?? [] }
}
