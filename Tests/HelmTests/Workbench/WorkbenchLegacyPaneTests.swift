import XCTest

@testable import Helm

/// **A bench saved by a build with a pane type this one does not have.**
///
/// REPLACES `WorkbenchArchonPaneTests`, whose whole subject — `Pane.Content.archonRun`,
/// `ArchonPaneRef`, `WorkbenchModel.openRun` and the cache behind it — was deleted with the
/// run pane. What survives is the harder property those tests never asserted: that removing a
/// pane type does not cost the operator anything but that pane.
///
/// The blast radius is why this is worth its own file. `WorkspaceContextStore.load` decodes
/// `[String: WorkspaceContext]` in ONE call, so an unreadable pane in one workspace would, if
/// nothing caught it, return `[:]` and wipe **every** workspace's columns, slots, tab order
/// and open canvases. There are three containments, and each has a test below: `Slot` skips
/// the pane, `WorkspaceContext` drops at most one workspace's bench, and the store keeps
/// everyone else's.
final class WorkbenchLegacyPaneTests: XCTestCase {
    /// Exactly what the previous build wrote: the discriminator plus the address under `run`.
    private let archonPane =
        #"{"id":"11111111-1111-1111-1111-111111111111","content":{"kind":"archonRun","run":{"kind":"run","id":"r1","workflowName":"implement"}}}"#

    private func bench(
        panes: [String], slot: String = "22222222-2222-2222-2222-222222222222"
    )
        -> String
    {
        """
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

    /// The pane goes; the terminal and the canvas beside it stay, and so does the slot.
    func testAnUnknownPaneKindIsSkippedAndTheRestOfTheSlotSurvives() throws {
        let terminal = "44444444-4444-4444-4444-444444444444"
        let canvas = "55555555-5555-5555-5555-555555555555"
        let stored = bench(panes: [terminalPane(terminal), archonPane, canvasPane(canvas)])

        let restored = try JSONDecoder().decode(Workbench.self, from: Data(stored.utf8))

        XCTAssertEqual(
            restored.panes.map { $0.id.uuidString.lowercased() }, [terminal, canvas],
            "the archonRun pane is dropped and nothing else is")
        XCTAssertEqual(restored.panes[0].content, .terminal(face: .terminal))
        XCTAssertEqual(
            restored.slots.count, 1, "a slot that still holds panes is not itself dropped")
    }

    /// `selected` named the pane that was skipped. `normalize()` re-points it rather than
    /// leaving a slot whose selection is a pane it does not hold — which would render as an
    /// empty slot with tabs above it.
    func testASelectionThatNamedTheSkippedPaneIsRepointed() throws {
        let terminal = "44444444-4444-4444-4444-444444444444"
        let stored = bench(panes: [archonPane, terminalPane(terminal)])

        let restored = try JSONDecoder().decode(Workbench.self, from: Data(stored.utf8))

        XCTAssertEqual(restored.slots[0].selected.uuidString.lowercased(), terminal)
        XCTAssertEqual(restored.focusedPane?.id.uuidString.lowercased(), terminal)
    }

    /// A bench that held **only** the removed type has nothing left to render and nothing to
    /// invent, so it throws — and `WorkspaceContext` turns that into one workspace falling
    /// back to its terminals, which is `Workbench.init(from:)`'s existing contract.
    func testABenchOfNothingButTheRemovedTypeIsDroppedRatherThanRenderedEmpty() throws {
        let stored = bench(panes: [archonPane])

        XCTAssertThrowsError(try JSONDecoder().decode(Workbench.self, from: Data(stored.utf8)))

        let context = try JSONDecoder().decode(
            WorkspaceContext.self,
            from: Data(
                #"{"terminalSessionIDs":[],"branchResolved":false,"workbench":\#(stored)}"#
                    .utf8))
        XCTAssertNil(context.workbench, "one workspace loses its bench, and says so in the log")
    }

    /// **The test the whole file exists for.** Through `WorkspaceContextStore` and a real
    /// `UserDefaults`, because that is the path a restart takes — and because the failure mode
    /// being guarded is at the *dictionary* level, which a bare `Pane.Content` through a fresh
    /// decoder cannot reach.
    func testOneWorkspacesLegacyPaneDoesNotWipeEveryOtherWorkspacesLayout() throws {
        let defaults = try isolatedDefaults("workbench-legacy-pane")
        let terminal = "44444444-4444-4444-4444-444444444444"
        let survivor = Workbench(terminal: UUID())
        // Written as raw JSON rather than encoded from a value, because the shape being
        // guarded is one THIS BUILD CANNOT PRODUCE. A round-trip through today's encoder would
        // prove nothing at all about a blob written by yesterday's.
        let stored = """
            {"/with-a-run":{"terminalSessionIDs":[],"branchResolved":false,\
            "workbench":\(bench(panes: [archonPane, terminalPane(terminal)]))},\
            "/plain":\(String(decoding: try JSONEncoder().encode(
                WorkspaceContext(workbench: survivor)), as: UTF8.self))}
            """
        defaults.set(stored, forKey: WorkspaceContextStore.key)

        let contexts = WorkspaceContextStore.load(from: defaults)

        XCTAssertEqual(
            contexts.count, 2,
            "one unreadable pane must not return [:] and take every workspace with it")
        XCTAssertEqual(
            contexts["/with-a-run"]?.workbench?.panes.map { $0.id.uuidString.lowercased() },
            [terminal], "that workspace keeps the panes this build still understands")
        XCTAssertEqual(
            contexts["/plain"]?.workbench, survivor,
            "and a workspace that never held one is untouched")
    }

    /// The encoder's side of it: there are two kinds now, and a third that decodes is a
    /// regression rather than tolerance.
    func testOnlyTwoPaneKindsEncodeAndAThirdDoesNotDecode() throws {
        for content in [
            Pane.Content.terminal(face: .terminal),
            .canvas(.file(URL(fileURLWithPath: "/tmp/a.md"))),
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
