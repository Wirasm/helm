import XCTest

@testable import Helm

/// Migration from a pre-bench context, and the containment that keeps one bad bench from
/// costing every workspace its terminals.
final class WorkbenchRestoreTests: XCTestCase {

    // MARK: - Migration

    func testAPreBenchContextMigratesToTheFrameTheOperatorSaw() throws {
        let first = UUID()
        let second = UUID()
        let context = WorkspaceContext(
            terminalSessionIDs: [first, second], selectedTerminalID: second,
            openArtifactPath: "/tmp/plan.md")

        let bench = try XCTUnwrap(Workbench.migrating(from: context))

        XCTAssertEqual(bench.columns.count, 2, "the canvas was a right dock, never a tab")
        XCTAssertEqual(
            bench.columns[0].slots[0].panes.map(\.id), [first, second],
            "the terminals come back as tabs, in order")
        XCTAssertEqual(
            bench.columns[0].slots[0].selected, second, "and the selected one is still selected")
        XCTAssertEqual(
            bench.columns[1].slots[0].panes.map(\.content),
            [.canvas(.file(path: "/tmp/plan.md"))])
        XCTAssertEqual(
            bench.focusedSlot, bench.columns[0].slots[0].id,
            "the operator was working in their terminal, not in the dock")
    }

    func testAContextWithNoCanvasMigratesToOneColumn() throws {
        let context = WorkspaceContext(terminalSessionIDs: [UUID()])

        let bench = try XCTUnwrap(Workbench.migrating(from: context))

        XCTAssertEqual(bench.columns.count, 1, "there was no dock to reproduce")
    }

    /// nil rather than an empty bench: `WorkbenchModel.activate` then builds today's 1×1
    /// frame from whatever the manager actually opened, so a first-run workspace behaves
    /// exactly as it always has.
    func testAnEmptyContextHasNothingToMigrate() {
        XCTAssertNil(Workbench.migrating(from: WorkspaceContext()))
    }

    /// `openArtifactPath` is a FILE path — the whole point of the field, and the reason
    /// #38 persisted nothing for a URL canvas. Migration must not invent one.
    func testAMigratedCanvasIsAlwaysAFileSource() throws {
        let context = WorkspaceContext(
            terminalSessionIDs: [UUID()], openArtifactPath: "/tmp/report.html")

        let bench = try XCTUnwrap(Workbench.migrating(from: context))

        XCTAssertEqual(bench.canvasPanes.map(\.content), [.canvas(.file(path: "/tmp/report.html"))])
    }

    func testEveryMigratedTerminalComesBackOnTheTerminalFace() throws {
        let context = WorkspaceContext(terminalSessionIDs: [UUID()])

        let bench = try XCTUnwrap(Workbench.migrating(from: context))

        XCTAssertEqual(
            bench.face(ofSelectedPaneIn: bench.focusedSlot), .terminal,
            "a pre-bench context could not describe a face, and the shell comes back empty")
    }

    // MARK: - Containment

    /// **The brief's constraint, as an executable assertion.**
    ///
    /// `WorkspaceContextStore.load` decodes `[String: WorkspaceContext]` in one call, so a
    /// value that throws anywhere inside it discards EVERY workspace's context — including
    /// the terminal restore position 1 shipped. The hand-written tolerant `init(from:)` is
    /// what contains a malformed bench to `workbench == nil` for its own workspace.
    func testACorruptBenchInOneWorkspaceStillRestoresEveryWorkspacesTerminals() throws {
        let good = UUID()
        let other = UUID()
        let blob = """
            {"/one":{"terminalSessionIDs":["\(good.uuidString)"],"branchResolved":false,
                     "workbench":{"columns":42}},
             "/two":{"terminalSessionIDs":["\(other.uuidString)"],"branchResolved":false}}
            """
        let defaults = try isolatedDefaults("workbench-restore")
        defaults.set(blob, forKey: WorkspaceContextStore.key)

        let contexts = WorkspaceContextStore.load(from: defaults)

        XCTAssertEqual(contexts.count, 2, "one bad bench must not discard the dictionary")
        XCTAssertNil(contexts["/one"]?.workbench, "the malformed bench degrades to nil")
        XCTAssertEqual(
            contexts["/one"]?.terminalSessionIDs, [good],
            "and its own workspace keeps the terminals the bench cannot describe")
        XCTAssertEqual(contexts["/two"]?.terminalSessionIDs, [other], "the sibling is untouched")
    }

    /// A workspace whose bench is nil falls back to the migration path, so a corrupt bench
    /// costs the arrangement and nothing else.
    func testACorruptBenchLeavesTheWorkspaceWithItsTerminalsThroughMigration() throws {
        let ids = [UUID(), UUID()]
        let blob = """
            {"/one":{"terminalSessionIDs":["\(ids[0].uuidString)","\(ids[1].uuidString)"],
                     "branchResolved":false,"workbench":{"columns":"not an array"}}}
            """
        let defaults = try isolatedDefaults("workbench-restore")
        defaults.set(blob, forKey: WorkspaceContextStore.key)

        let context = try XCTUnwrap(WorkspaceContextStore.load(from: defaults)["/one"])
        let bench = try XCTUnwrap(context.workbench ?? .migrating(from: context))

        XCTAssertEqual(
            bench.terminalPaneIDs, ids, "the tab row survives a bench that does not")
    }

    func testABlobWrittenBeforeTheBenchExistedStillDecodes() throws {
        let id = UUID()
        let blob = """
            {"/one":{"terminalSessionIDs":["\(id.uuidString)"],"branchResolved":true,
                     "openArtifactPath":"/tmp/a.md"}}
            """
        let defaults = try isolatedDefaults("workbench-restore")
        defaults.set(blob, forKey: WorkspaceContextStore.key)

        let context = try XCTUnwrap(WorkspaceContextStore.load(from: defaults)["/one"])

        XCTAssertNil(context.workbench, "a missing key is not an error")
        XCTAssertEqual(context.terminalSessionIDs, [id])
        XCTAssertEqual(context.openArtifactPath, "/tmp/a.md")
    }

    func testABenchRoundTripsThroughTheStore() throws {
        var bench = Workbench(terminal: UUID())
        bench.insert(
            Pane(content: .canvas(.url(URL(string: "http://localhost:3000")!))), at: .column)
        let defaults = try isolatedDefaults("workbench-restore")

        WorkspaceContextStore.save(
            ["/one": WorkspaceContext(workbench: bench)], to: defaults)

        XCTAssertEqual(
            WorkspaceContextStore.load(from: defaults)["/one"]?.workbench, bench,
            "the whole arrangement comes back, including which canvas held which URL")
    }
}
