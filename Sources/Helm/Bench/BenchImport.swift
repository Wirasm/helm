import Foundation
import HelmWire

/// The one-time move of the benches helm used to keep in its defaults into benchd (#354).
///
/// **Once, into an empty document, as `helm`.** The first time helm finds benchd holding
/// nothing, the workspaces it saved before benchd owned the bench — each bench and each shelf —
/// go over as one `workspace/import`, and a marker is written so it never happens again. benchd
/// refuses an import into a document that holds anything, so two helms cannot both win.
///
/// **Why this is still here.** Every helm that ran before this build kept its benches under
/// `helmWorkspaces`, `helmSelectedWorkspace` and `helmWorkspaceContexts`, and nothing else has
/// them. The saved state is read, never touched: a helm built from before the unwire still finds
/// it where it left it. This file, `Workbench`'s `Decodable` and `BenchDocument.Bench(_:)` are
/// the whole of the converter; they can go one release after every machine has imported.
///
/// A stored url or empty canvas (#376) does not decode — `Slot` skips it and logs that it did —
/// and the chat face (#375) was never saved.
enum BenchImport {
    static let markerKey = "benchImportedAt"
    static let listKey = "helmWorkspaces"
    static let selectionKey = "helmSelectedWorkspace"
    static let contextsKey = "helmWorkspaceContexts"

    /// What helm saved for one workspace, as far as the import reads it.
    ///
    /// **Each field is read on its own, and a bad one costs only itself.** The contexts are one
    /// dictionary for every workspace, so a synthesized decoder failing one field would fail the
    /// whole dictionary and import nothing. A bench that will not decode leaves that workspace
    /// with one fresh terminal, said in the log; a shelf that will not decode is dropped quietly,
    /// because the operator already declined it.
    struct Saved: Decodable {
        var workbench: Workbench?
        var shelvedBench: Workbench?

        private enum CodingKeys: String, CodingKey { case workbench, shelvedBench }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            do {
                workbench = try container.decodeIfPresent(Workbench.self, forKey: .workbench)
            } catch {
                NSLog(
                    "helm: a saved workbench could not be read and is imported as one "
                        + "terminal: %@", String(describing: error))
            }
            shelvedBench =
                (try? container.decodeIfPresent(Workbench.self, forKey: .shelvedBench)) ?? nil
        }
    }

    /// The document helm's saved state describes. nil when there is nothing to move.
    static func document(from defaults: UserDefaults) -> BenchDocument? {
        let paths = (decoded([Workspace].self, at: listKey, in: defaults) ?? []).map(\.path.value)
        guard !paths.isEmpty else { return nil }
        // Keyed by `WorkspacePath.value`, as the list is.
        let contexts = decoded([String: Saved].self, at: contextsKey, in: defaults) ?? [:]
        let workspaces = paths.map { path -> BenchDocument.Workspace in
            let saved = contexts[path]
            // A workspace never visited has no bench saved; it gets the one a first visit would.
            let bench = saved?.workbench ?? Workbench(terminal: UUID())
            return BenchDocument.Workspace(
                path: path, bench: BenchDocument.Bench(bench),
                shelved: saved?.shelvedBench.map(BenchDocument.Bench.init))
        }
        let selected = defaults.string(forKey: selectionKey).map { WorkspacePath($0).value }
            .flatMap { paths.contains($0) ? $0 : nil }
        return BenchDocument(workspaces: workspaces, active: selected ?? paths.first)
    }

    private static func decoded<Value: Decodable>(
        _: Value.Type, at key: String, in defaults: UserDefaults
    ) -> Value? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: Data(raw.utf8))
    }

    /// What `RootView` hands `WorkbenchModel.followDocuments`: import first, then let the
    /// workspace list follow the newest document.
    ///
    /// **The order is the point.** The import draws the document it made before returning, so the
    /// list follows that one rather than the empty one this call was handed.
    @MainActor
    static func follower(
        workspaces: WorkspaceModel, workbench: WorkbenchModel,
        defaults: UserDefaults = DefaultsDomain.store
    ) -> (BenchDocument) -> Void {
        { [weak workspaces, weak workbench] document in
            guard let workspaces, let workbench else { return }
            runOnce(into: document, from: defaults, through: workbench)
            workspaces.follow(workbench.document ?? document)
        }
    }

    /// Import if benchd holds nothing and this helm never has. Called with each document; does
    /// nothing after the first that qualifies.
    @MainActor
    static func runOnce(
        into document: BenchDocument, from defaults: UserDefaults, through sink: WorkbenchModel
    ) {
        guard document.workspaces.isEmpty, defaults.object(forKey: markerKey) == nil,
            let saved = self.document(from: defaults)
        else { return }
        sink.send(.workspaceImport(saved), by: .helm)
        // Marked only when it landed: a refused import (another helm won the race) or an
        // unreachable benchd leaves it to be tried with the next empty document.
        if sink.document?.workspaces.isEmpty == false { defaults.set(Date(), forKey: markerKey) }
    }
}
