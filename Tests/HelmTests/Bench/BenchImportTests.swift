import Foundation
import HelmWire
import XCTest

@testable import Helm

/// The one-time move of the benches helm used to keep in its defaults into an empty benchd
/// document — and the tolerant read of that saved state, which is the import's to get right now:
/// nothing else reads it.
@MainActor
final class BenchImportTests: XCTestCase {
    private let a = Workspace(path: "/tmp/helm-import-a")
    private let b = Workspace(path: "/tmp/helm-import-b")

    /// Defaults the way a helm before the unwire left them: two workspaces open, `a` selected,
    /// `a` with a bench of a terminal and a canvas and a shelf, `b` never visited.
    private func saved(_ label: String) throws -> (UserDefaults, Workbench, Workbench) {
        let defaults = try isolatedDefaults(label)
        let bench = Workbench(panes: [
            Pane(content: .terminal()), Pane(content: .canvas(.file("/tmp/plan.md"))),
        ])
        let shelf = Workbench(terminal: UUID())
        let contexts = [a.path.value: ["workbench": bench, "shelvedBench": shelf]]
        defaults.set(
            String(decoding: try JSONEncoder().encode(contexts), as: UTF8.self),
            forKey: BenchImport.contextsKey)
        defaults.set(
            String(decoding: try JSONEncoder().encode([a, b]), as: UTF8.self),
            forKey: BenchImport.listKey)
        defaults.set(a.path.value, forKey: BenchImport.selectionKey)
        return (defaults, bench, shelf)
    }

    private func snapshot(_ defaults: UserDefaults) -> [String?] {
        [BenchImport.listKey, BenchImport.selectionKey, BenchImport.contextsKey].map {
            defaults.string(forKey: $0)
        }
    }

    func testTheSavedBenchesAndShelvesBecomeOneDocument() throws {
        let (defaults, bench, shelf) = try saved("import-document")

        let document = try XCTUnwrap(BenchImport.document(from: defaults))

        XCTAssertEqual(document.active, a.path.value)
        XCTAssertEqual(document.workspaces.map(\.path), [a.path.value, b.path.value])
        XCTAssertEqual(document.workspaces[0].bench, BenchDocument.Bench(bench))
        XCTAssertEqual(document.workspaces[0].shelved, BenchDocument.Bench(shelf))
        XCTAssertEqual(
            document.workspaces[1].bench.columns.flatMap(\.slots).flatMap(\.panes).count, 1,
            "a workspace never visited gets the one shell a first visit would")
    }

    func testNothingSavedIsNothingToImport() throws {
        XCTAssertNil(BenchImport.document(from: try isolatedDefaults("import-nothing")))
    }

    /// Into an empty document once, as helm; marked; the saved keys left as they were.
    func testAnEmptyDocumentGetsTheImportOnceAndTheSavedStateIsUntouched() throws {
        let (defaults, _, _) = try saved("import-once")
        let before = snapshot(defaults)
        let (server, client) = try toyBenchd(BenchDocument(workspaces: [], active: nil))
        let workbench = WorkbenchModel(
            terminals: TerminalManager(), agents: .blind, client: client)
        XCTAssertTrue(Eventually.holds { workbench.document != nil })
        let workspaces = WorkspaceModel(readBranch: { _ in nil })

        // Wired the way `RootView` wires it, after the first (empty) document has arrived.
        let follow = BenchImport.follower(
            workspaces: workspaces, workbench: workbench, defaults: defaults)
        workbench.followDocuments(follow)
        follow(BenchDocument(workspaces: [], active: nil))

        let imports = server.verbs.filter { $0["verb"] as? String == "workspace/import" }
        XCTAssertEqual(imports.count, 1, "once, however many empty documents follow")
        XCTAssertEqual((imports.first?["by"] as? [String: Any])?["kind"] as? String, "helm")
        XCTAssertNotNil(defaults.object(forKey: BenchImport.markerKey))
        XCTAssertEqual(workbench.document?.workspaces.count, 2)
        XCTAssertEqual(
            workspaces.workspaces, [a, b],
            "the list follows the imported document, not the empty one")
        XCTAssertEqual(workspaces.selectedWorkspace, a)
        XCTAssertEqual(snapshot(defaults), before, "the saved state is read, never written")
    }

    /// A refused import is not marked: the next empty document tries again.
    func testARefusedImportIsNotMarked() throws {
        let (defaults, _, _) = try saved("import-refused")
        let server = try FakeBenchd(
            document: DocumentAt(seq: 0, document: BenchDocument(workspaces: [], active: nil)))
        server.answer = { request in
            ["id": request["id"] ?? "", "status": "refused", "reason": "the document is not empty"]
        }
        let client = BenchClient(socketPath: server.path)
        let workbench = WorkbenchModel(
            terminals: TerminalManager(), agents: .blind, client: client)
        defer {
            client.stop()
            server.stop()
        }
        XCTAssertTrue(Eventually.holds { workbench.document != nil })

        BenchImport.runOnce(
            into: try XCTUnwrap(workbench.document), from: defaults, through: workbench)

        XCTAssertNil(defaults.object(forKey: BenchImport.markerKey))
    }

    // MARK: - Reading what older builds saved

    /// Exactly what a build with a run pane wrote: the discriminator plus the address under `run`.
    private let archonPane =
        #"{"id":"11111111-1111-1111-1111-111111111111","content":{"kind":"archonRun","run":{"kind":"run","id":"r1","workflowName":"implement"}}}"#

    private func bench(panes: [String]) -> String {
        let slot = "22222222-2222-2222-2222-222222222222"
        return """
            {"columns":[{"id":"33333333-3333-3333-3333-333333333333","width":1,\
            "slots":[{"id":"\(slot)","height":1,\
            "selected":"11111111-1111-1111-1111-111111111111",\
            "panes":[\(panes.joined(separator: ","))]}]}],"focusedSlot":"\(slot)"}
            """
    }

    private func terminalPane(_ id: String) -> String {
        #"{"id":"\#(id)","content":{"kind":"terminal"}}"#
    }

    private func canvasPane(_ id: String) -> String {
        """
        {"id":"\(id)","content":{"kind":"canvas","source":\
        {"kind":"file","path":"/tmp/plan.md"}}}
        """
    }

    /// The URL canvas left in #376, and a stored one goes the way an unknown pane kind does:
    /// its source no longer decodes, so `Slot` skips the pane and keeps the rest.
    func testAStoredURLOrEmptyCanvasIsSkippedAndTheRestOfTheSlotSurvives() throws {
        let terminal = "44444444-4444-4444-4444-444444444444"
        let file = "55555555-5555-5555-5555-555555555555"
        let url = """
            {"id":"66666666-6666-6666-6666-666666666666","content":{"kind":"canvas","source":\
            {"kind":"url","address":"http://localhost:3000"}}}
            """
        let empty = """
            {"id":"77777777-7777-7777-7777-777777777777","content":{"kind":"canvas","source":\
            {"kind":"empty"}}}
            """
        let stored = bench(panes: [terminalPane(terminal), url, empty, canvasPane(file)])

        let restored = try JSONDecoder().decode(Workbench.self, from: Data(stored.utf8))

        XCTAssertEqual(
            restored.panes.map { $0.id.uuidString.lowercased() }, [terminal, file],
            "the URL and empty canvases are dropped and nothing else is")
    }

    /// The pane goes; the terminal and the canvas beside it stay. Re-pointing a `selected` that
    /// named it is benchd's, on import (`bench-doc`'s `legacy_pane.rs`).
    func testAnUnknownPaneKindIsSkippedAndTheRestOfTheSlotSurvives() throws {
        let terminal = "44444444-4444-4444-4444-444444444444"
        let canvas = "55555555-5555-5555-5555-555555555555"
        let stored = bench(panes: [terminalPane(terminal), archonPane, canvasPane(canvas)])

        let restored = try JSONDecoder().decode(Workbench.self, from: Data(stored.utf8))

        XCTAssertEqual(
            restored.panes.map { $0.id.uuidString.lowercased() }, [terminal, canvas],
            "the archonRun pane is dropped and nothing else is")
        XCTAssertEqual(restored.panes[0].content, .terminal())
    }

    /// **The test this section exists for.** A bench that held only the removed type has
    /// nothing to render, so that one workspace is imported as a fresh terminal — and one
    /// unreadable pane in one workspace does not cost every other workspace its bench, which is
    /// the failure a single decode of the whole dictionary would have. Written as raw JSON,
    /// because the shape guarded is one this build cannot produce.
    func testOneWorkspacesUnreadableBenchDoesNotCostTheOthersTheirs() throws {
        let defaults = try isolatedDefaults("import-legacy-pane")
        let survivor = Workbench(terminal: UUID())
        let terminal = "44444444-4444-4444-4444-444444444444"
        let encodedSurvivor = String(decoding: try JSONEncoder().encode(survivor), as: UTF8.self)
        defaults.set(
            """
            {"/only-a-run":{"terminalSessionIDs":[],"workbench":\(bench(panes: [archonPane]))},\
            "/with-a-run":{"workbench":\(bench(panes: [archonPane, terminalPane(terminal)]))},\
            "/plain":{"workbench":\(encodedSurvivor)}}
            """, forKey: BenchImport.contextsKey)
        defaults.set(#"["/only-a-run","/with-a-run","/plain"]"#, forKey: BenchImport.listKey)

        let document = try XCTUnwrap(BenchImport.document(from: defaults))
        let panes = document.workspaces.map {
            $0.bench.columns.flatMap(\.slots).flatMap(\.panes).map(\.id)
        }

        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(panes[0].count, 1, "a bench of nothing readable is one fresh terminal")
        XCTAssertNotEqual(
            panes[0].first?.uuidString.lowercased(), "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(panes[1].map { $0.uuidString.lowercased() }, [terminal])
        XCTAssertEqual(document.workspaces[2].bench, BenchDocument.Bench(survivor))
    }

    /// A third pane kind that decodes would be a regression rather than tolerance.
    func testAPaneKindThisBuildNeverHadDoesNotDecode() throws {
        for content in [
            Pane.Content.terminal(), .canvas(.file(URL(fileURLWithPath: "/tmp/a.md"))), .browser,
        ] {
            XCTAssertEqual(
                try JSONDecoder().decode(Pane.Content.self, from: JSONEncoder().encode(content)),
                content)
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"archonRun"}"#.utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(Pane.Content.self, from: Data(#"{"kind":"future"}"#.utf8)))
    }
}
