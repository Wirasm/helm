import HelmWire

// What the bench model knows about benchd's drawers (#356). In an extension because the class
// body is at its size limit (#418).
extension WorkbenchModel {
    /// The drawer shown over the bench, if one is. While it is, it has the keyboard.
    var openDrawer: BenchDocument.Drawer? {
        document?.openDrawer.flatMap { name in document?.drawers.first { $0.name == name } }
    }

    /// The workspace a pane's live object belongs to: none for a pane in a drawer, which is
    /// beside the workspaces rather than in one, so closing a workspace never takes it.
    func home(of pane: Pane.ID) -> WorkspacePath? {
        document?.drawer(holding: pane) == nil ? workspacePath : nil
    }
}
