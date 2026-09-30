import Foundation
import HelmWire
import SwiftUI

/// Archon's runs as a `SurfaceKind` (#382): an `ArchonModel` per pane, drawn by
/// `ArchonDrawerView`. It lives in the `archon` drawer (⌘⇧R) along the bottom of the window,
/// the way the sessions list lives in its drawer.
@MainActor
final class ArchonPaneKind: SurfaceKind {
    /// Weak for `SessionsPaneKind`'s reason: the registration can outlive a closed window.
    private weak var workbench: WorkbenchModel?
    private weak var terminals: TerminalManager?

    init(workbench: WorkbenchModel, terminals: TerminalManager) {
        self.workbench = workbench
        self.terminals = terminals
    }

    let kind: Pane.Content.Kind = .archon

    func make(for pane: Pane, in workspace: WorkspacePath?) -> ArchonDrawer? {
        guard let workbench, let terminals else { return nil }
        let host = BenchdHost(client: workbench.client)
        return ArchonDrawer(
            model: ArchonModel(client: ArchonCLI(host: host), opener: .live(host: host)),
            workspace: { [weak workbench] in workbench?.workspacePath },
            runInNewTerminal: { [weak workbench, weak terminals] line in
                guard let workbench, let terminals else { return "helm is closing" }
                return await NewTerminalLine.run(line, workbench: workbench, terminals: terminals)
            })
    }

    func view(of drawer: ArchonDrawer, in slot: SurfaceSlot) -> AnyView {
        AnyView(ArchonDrawerView(drawer: drawer, holdsKeyboard: slot.holdsKeyboard))
    }

    func tab(of drawer: ArchonDrawer, in slot: SurfaceSlot) -> AnyView {
        AnyView(
            PaneTab(
                title: slot.pane.name.text ?? "archon", truncation: .tail,
                closeHelp: "Close the Archon list", slot: slot
            ) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10))
            })
    }

    func close(_ drawer: ArchonDrawer) {}
}

/// One Archon pane's live object: the model, plus the two things only the bench can answer —
/// which workspace is on screen, and a terminal to follow a run's log in.
@MainActor
final class ArchonDrawer {
    let model: ArchonModel
    let workspace: @MainActor () -> WorkspacePath?
    /// Opens a terminal on the bench and runs one line in it; answers why it could not.
    let runInNewTerminal: @MainActor (String) async -> String?

    init(
        model: ArchonModel, workspace: @escaping @MainActor () -> WorkspacePath?,
        runInNewTerminal: @escaping @MainActor (String) async -> String?
    ) {
        self.model = model
        self.workspace = workspace
        self.runInNewTerminal = runInNewTerminal
    }
}
