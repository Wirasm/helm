import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The one-time move of helm's saved benches into an empty benchd document.
@MainActor
final class BenchImportTests: XCTestCase {
    private let a = Workspace(path: "/tmp/helm-import-a")
    private let b = Workspace(path: "/tmp/helm-import-b")

    /// A saved model with two workspaces: `a` has a bench of two terminals and a shelf, `b` was
    /// never visited.
    private func saved(
        _ label: String
    ) throws -> (WorkspaceModel, UserDefaults, Workbench, Workbench) {
        let defaults = try isolatedDefaults(label)
        let bench = Workbench(panes: [
            Pane(content: .terminal()), Pane(content: .canvas(.file("/tmp/plan.md"))),
        ])
        let shelf = Workbench(terminal: UUID())
        var context = WorkspaceContext()
        context.workbench = bench
        context.shelvedBench = shelf
        WorkspaceContextStore.save([a.path.value: context], to: defaults)
        let model = WorkspaceModel(defaults: defaults)
        model.open(a)
        model.open(b)
        model.select(a)
        return (model, defaults, bench, shelf)
    }

    func testTheSavedBenchesAndShelvesBecomeOneDocument() throws {
        let (model, _, bench, shelf) = try saved("import-document")

        let document = try XCTUnwrap(BenchImport.document(from: model))

        XCTAssertEqual(document.active, a.path.value)
        XCTAssertEqual(document.workspaces.map(\.path), [a.path.value, b.path.value])
        XCTAssertEqual(document.workspaces[0].bench, BenchDocument.Bench(bench))
        XCTAssertEqual(document.workspaces[0].shelved, BenchDocument.Bench(shelf))
        XCTAssertEqual(
            document.workspaces[1].bench.columns.flatMap(\.slots).flatMap(\.panes).count, 1,
            "a workspace never visited gets the one shell a first visit would")
    }

    /// Into an empty document once, as helm; marked; the saved keys left as they were.
    func testAnEmptyDocumentGetsTheImportOnceAndTheSavedStateIsUntouched() throws {
        let (model, defaults, _, _) = try saved("import-once")
        let before = (
            WorkspacePersistence.load(from: defaults), WorkspaceContextStore.load(from: defaults)
        )
        let server = try FakeBenchd(
            document: DocumentAt(seq: 0, document: BenchDocument(workspaces: [], active: nil)))
        server.answerWith { request in
            guard let args = request["args"] as? [String: Any], let raw = args["document"],
                let data = try? JSONSerialization.data(withJSONObject: raw),
                let document = try? JSONDecoder().decode(BenchDocument.self, from: data)
            else { return nil }
            return DocumentAt(seq: 1, document: document)
        }
        let client = BenchClient(socketPath: server.path)
        let workbench = WorkbenchModel(
            terminals: TerminalManager(), agents: .blind, mode: .daemon(client))
        defer {
            client.stop()
            server.stop()
        }
        XCTAssertTrue(Eventually.holds { workbench.document != nil })

        // Wired the way `RootView` wires it, after the first (empty) document has arrived.
        let follow = BenchImport.follower(model: model, workbench: workbench)
        workbench.followDocuments(follow)
        follow(BenchDocument(workspaces: [], active: nil))

        let imports = server.verbs.filter { $0["verb"] as? String == "workspace/import" }
        XCTAssertEqual(imports.count, 1, "once, however many empty documents follow")
        XCTAssertEqual((imports.first?["by"] as? [String: Any])?["kind"] as? String, "helm")
        XCTAssertTrue(model.hasImportedIntoBench)
        XCTAssertEqual(workbench.document?.workspaces.count, 2)
        XCTAssertEqual(
            model.workspaces, [a, b], "the list follows the imported document, not the empty one")
        XCTAssertEqual(model.selectedWorkspace, a)
        XCTAssertEqual(WorkspacePersistence.load(from: defaults), before.0)
        XCTAssertEqual(
            WorkspaceContextStore.load(from: defaults), before.1,
            "the saved workspaces and benches are read, never written")
    }

    /// A refused import is not marked: the next empty document tries again.
    func testARefusedImportIsNotMarked() throws {
        let (model, _, _, _) = try saved("import-refused")
        let server = try FakeBenchd(
            document: DocumentAt(seq: 0, document: BenchDocument(workspaces: [], active: nil)))
        server.answer = { request in
            ["id": request["id"] ?? "", "status": "refused", "reason": "the document is not empty"]
        }
        let client = BenchClient(socketPath: server.path)
        let workbench = WorkbenchModel(
            terminals: TerminalManager(), agents: .blind, mode: .daemon(client))
        defer {
            client.stop()
            server.stop()
        }
        XCTAssertTrue(Eventually.holds { workbench.document != nil })

        BenchImport.runOnce(
            into: try XCTUnwrap(workbench.document), from: model, through: workbench)

        XCTAssertFalse(model.hasImportedIntoBench)
    }
}
