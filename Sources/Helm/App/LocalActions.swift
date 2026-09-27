import HelmWire

/// Carries out what a key, a menu item or a button asks for (`Actions`).
///
/// **Composition, which is why it is in `App/`.** A verb needs the bench and the workspace list
/// to resolve against; the local actions each touch one owner — the focused terminal, the
/// artifact popover, the note store. `RootView` holds all of them and builds this.
@MainActor
final class LocalActions: ActionPerformer {
    private let workbench: WorkbenchModel
    private let workspaces: WorkspaceModel
    private let terminals: TerminalManager
    private let just: JustRuns
    private let palette: CommandPalette

    init(
        workbench: WorkbenchModel, workspaces: WorkspaceModel, terminals: TerminalManager,
        just: JustRuns = JustRuns(), palette: CommandPalette = CommandPalette()
    ) {
        self.workbench = workbench
        self.workspaces = workspaces
        self.terminals = terminals
        self.just = just
        self.palette = palette
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
        case let .just(recipe):
            just.run(recipe)
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
        case .toggleZoom:
            workbench.isZoomed.toggle()
        case .newNote:
            Task { await workbench.newNote() }
        case .toggleKeepAwake:
            KeepAwake.shared.toggle()
        case .toggleCommandPalette:
            palette.toggle()
        }
    }
}
