import HelmWire

/// Carries out what a key, a menu item or a button asks for (`Actions`).
///
/// **Composition, which is why it is in `App/`.** A verb needs the bench and the workspace list
/// to resolve against; the local actions each touch one owner — the focused terminal, the
/// artifact popover, the rail, the note store. `RootView` holds all of them and builds this.
@MainActor
final class LocalActions: ActionPerformer {
    private let workbench: WorkbenchModel
    private let workspaces: WorkspaceModel
    private let rail: ArchonRailModel
    private let terminals: TerminalManager

    init(
        workbench: WorkbenchModel, workspaces: WorkspaceModel, rail: ArchonRailModel,
        terminals: TerminalManager
    ) {
        self.workbench = workbench
        self.workspaces = workspaces
        self.rail = rail
        self.terminals = terminals
    }

    func perform(_ action: KeyBinding.Action) {
        switch action {
        case let .verb(template):
            guard
                let verb = template.resolve(
                    bench: workbench.bench,
                    workspaces: workspaces.workspaces.map(\.path),
                    active: workspaces.selectedWorkspace?.path)
            else { return }
            workbench.send(verb, by: .operatorGesture)
        case let .local(local):
            perform(local)
        }
    }

    private func perform(_ action: LocalAction) {
        switch action {
        case let .adjustFontSize(step):
            workbench.focusedTerminal?.adjustFontSize(step)
        case let .jumpToPrompt(offset):
            guard terminals.anyTerminalHasFocus else { return }
            workbench.focusedTerminal?.jumpToPrompt(by: offset)
        case .openWorkspacePanel:
            guard let folder = WorkspacePanel.choose() else { return }
            workbench.send(.workspaceOpen(path: folder.path.value), by: .operatorGesture)
        case .openArtifactPanel:
            workbench.isBrowserOpen.toggle()
        case .toggleRail:
            rail.toggleVisibility()
        case .newNote:
            Task { await workbench.newNote() }
        }
    }
}
