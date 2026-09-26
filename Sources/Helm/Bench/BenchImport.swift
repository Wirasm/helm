import Foundation
import HelmWire

/// The one-time move of helm's saved benches into benchd (#354).
///
/// **Once, into an empty document, as `helm`.** The first time a helm in daemon mode finds benchd
/// holding nothing, the workspaces it has saved — each bench and each shelf — go over as one
/// `workspace/import`, and a marker is written so it never happens again. benchd refuses an
/// import into a document that holds anything, so two helms cannot both win.
///
/// **The saved state is read, never touched.** The old keys stay as they were, so unsetting
/// `HELM_BENCH` finds everything where it left it. A stored url or empty canvas (#376) does not
/// even decode — `Slot` skips it and logs that it did — and the chat face (#375) was never saved.
enum BenchImport {
    static let markerKey = "benchImportedAt"

    /// The document helm's saved state describes. nil when there is nothing to move.
    @MainActor
    static func document(from model: WorkspaceModel) -> BenchDocument? {
        guard !model.workspaces.isEmpty else { return nil }
        let workspaces = model.workspaces.map { workspace -> BenchDocument.Workspace in
            let context = model.contexts[workspace.path.value] ?? WorkspaceContext()
            // A workspace never visited has no bench saved; it gets the one a first visit would.
            let saved =
                context.workbench ?? .migrating(from: context) ?? Workbench(terminal: UUID())
            return BenchDocument.Workspace(
                path: workspace.path.value, bench: BenchDocument.Bench(saved),
                shelved: context.shelvedBench.map(BenchDocument.Bench.init))
        }
        let active = model.selectedWorkspace ?? model.workspaces.first
        return BenchDocument(workspaces: workspaces, active: active?.path.value)
    }

    /// What `RootView` hands `WorkbenchModel.followDocuments` in daemon mode: import first, then
    /// let the workspace list follow the newest document.
    ///
    /// **The order is the point.** Following an empty document empties the workspace list, and
    /// the import reads that list — so following first imported nothing, which is what the first
    /// live run did. And the import draws the document it made before returning, so the list
    /// follows that one rather than the empty one this call was handed.
    @MainActor
    static func follower(
        model: WorkspaceModel, workbench: WorkbenchModel
    ) -> (BenchDocument) -> Void {
        { [weak model, weak workbench] document in
            guard let model, let workbench else { return }
            runOnce(into: document, from: model, through: workbench)
            model.follow(workbench.document ?? document)
        }
    }

    /// Import if benchd holds nothing and this helm never has. Called with each document; does
    /// nothing after the first that qualifies.
    @MainActor
    static func runOnce(
        into document: BenchDocument, from model: WorkspaceModel, through sink: WorkbenchModel
    ) {
        guard document.workspaces.isEmpty, !model.hasImportedIntoBench,
            let saved = self.document(from: model)
        else { return }
        sink.send(.workspaceImport(saved), by: .helm)
        // Marked only when it landed: a refused import (another helm won the race) or an
        // unreachable benchd leaves it to be tried with the next empty document.
        if sink.document?.workspaces.isEmpty == false { model.markImportedIntoBench() }
    }
}
