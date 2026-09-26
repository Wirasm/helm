import HelmWire
import XCTest

@testable import Helm

/// #85: the first time a workspace is shown, a bench worth asking about is offered — restore or
/// fresh — instead of reopening every pane.
///
/// The ticket's own last acceptance line shapes this file — *"the decision logic is reachable
/// from `swift test`, not trapped in a `View`"* — so the first half runs against
/// `BenchMountPolicy` with no model at all, and the second half walks the question through
/// `WorkbenchModel` against a toy benchd. The question stays helm's (plan D4 of #354); the
/// bench and its shelf are benchd's, and the answer goes back as a verb.
@MainActor
final class BenchMountTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-bench-mount")

    /// A bench of `terminals` terminals and `canvases` canvases, each in a column of its own.
    private func stored(terminals: Int, canvases: Int = 0) -> BenchDocument.Bench {
        let panes =
            (0..<max(terminals, 1)).map { _ in ToyBench.terminal() }
            + (0..<canvases).map {
                BenchDocument.Pane(id: UUID(), surface: .canvas(path: "/tmp/a\($0).md"))
            }
        let slots = panes.map {
            BenchDocument.Slot(id: UUID(), panes: [$0], selected: $0.id, height: 1)
        }
        return .init(
            columns: slots.map { .init(id: UUID(), slots: [$0], width: 1 / Double(slots.count)) },
            focusedSlot: slots[0].id)
    }

    private func bench(terminals: Int, canvases: Int = 0) throws -> Workbench {
        try XCTUnwrap(Workbench(document: stored(terminals: terminals, canvases: canvases)))
    }

    /// helm shown `bench` (and `shelved`) for the first time, with the question left open.
    private func showing(
        _ bench: BenchDocument.Bench, shelved: BenchDocument.Bench? = nil
    ) throws -> ToyRig {
        try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: bench, shelved: shelved)],
                active: workspace.value),
            answering: false)
    }

    // MARK: - When the question is asked

    func testABenchWorthAskingAboutIsAskedAboutAndNamesItsPaneCount() throws {
        let saved = try bench(terminals: 3, canvases: 2)

        let offer = try XCTUnwrap(
            BenchMountPolicy.offer(bench: saved, shelved: nil),
            "a five-pane bench must be offered, not reopened")

        XCTAssertEqual(
            offer.paneCount, 5, "the count is the offer — it is what makes bloat visible")
        XCTAssertEqual(offer.terminalCount, 3)
        XCTAssertEqual(offer.canvasCount, 2)
        XCTAssertEqual(offer.bench, saved, "and answering restores exactly what was counted")
    }

    /// Restoring one empty shell and building one empty shell differ only in a uuid nobody can
    /// see, so a question there would be chrome with no decision under it.
    func testOneEmptyShellIsNotAskedAbout() throws {
        XCTAssertNil(BenchMountPolicy.offer(bench: try bench(terminals: 1), shelved: nil))
    }

    /// The pane count is not the only thing that makes a bench worth asking about. A single
    /// pane whose whole value is the conversation it held is exactly the case #63 exists for.
    func testOnePaneStillAsksWhenItHeldAnAgent() throws {
        let saved = Workbench(
            panes: [
                Pane(
                    content: .terminal(
                        agent: ResumableAgent(command: "claude", session: "abc", cwd: "/tmp")))
            ])

        let offer = try XCTUnwrap(
            BenchMountPolicy.offer(bench: saved, shelved: nil),
            "a pane that held an agent is worth a question even on its own")

        XCTAssertEqual(offer.paneCount, 1)
        XCTAssertEqual(offer.agentCount, 1, "and the offer says what declining costs")
    }

    // MARK: - The shelf

    /// *"Fresh means do not open it now, never forget it."* The declined bench is offered
    /// again while the bench is still the throwaway shell that replaced it.
    func testAShelvedBenchIsOfferedBackWhileTheBenchIsStillTheFreshShell() throws {
        let declined = try bench(terminals: 6)

        let offer = try XCTUnwrap(
            BenchMountPolicy.offer(bench: try bench(terminals: 1), shelved: declined),
            "a declined bench must still be reachable")

        XCTAssertEqual(offer.bench, declined, "the question is about what was declined")
        XCTAssertEqual(offer.paneCount, 6)
    }

    /// …and it stops offering itself as soon as the operator has built something worth
    /// keeping, so a decline does not turn into a nag.
    func testTheShelfStopsBeingOfferedOnceTheBenchIsWorthSomething() throws {
        let worked = try bench(terminals: 2)

        let offer = try XCTUnwrap(
            BenchMountPolicy.offer(bench: worked, shelved: try bench(terminals: 6)))

        XCTAssertEqual(
            offer.bench, worked,
            "the question is about the bench the operator actually left, not the old shelf")
    }

    // MARK: - The model, and what happens while the question is open

    func testWhileTheQuestionIsOpenNothingIsDrawnSpawnedOrSent() throws {
        let rig = try showing(stored(terminals: 3))

        XCTAssertNotNil(rig.model.restoreOffer, "the question is open")
        XCTAssertNil(rig.model.bench, "and nothing is drawn behind it")
        XCTAssertTrue(
            rig.terminals.sessions(for: workspace).isEmpty,
            "a question that has already spawned the thing it asks about is not a question")
        XCTAssertTrue(rig.server.verbs.isEmpty, "an open question costs benchd's bench nothing")
    }

    func testRestoringDrawsExactlyWhatWasOfferedAndSendsNothing() throws {
        let saved = try bench(terminals: 3)
        let rig = try showing(stored(terminals: 3))
        let offered = try XCTUnwrap(rig.model.restoreOffer?.bench)

        rig.model.answer(.restore)

        XCTAssertNil(rig.model.restoreOffer)
        XCTAssertEqual(rig.model.bench, offered)
        XCTAssertEqual(rig.model.bench?.panes.count, saved.panes.count)
        XCTAssertEqual(
            rig.terminals.sessions(for: workspace).map(\.id), offered.terminalPaneIDs,
            "the terminals come back under their pane ids")
        XCTAssertTrue(rig.server.verbs.isEmpty, "benchd already holds that bench")
        XCTAssertNil(rig.model.shelvedBench, "a bench that was opened is not shelved")
    }

    func testFreshIsAResetAndShelvesWhatItDeclined() throws {
        let rig = try showing(stored(terminals: 4))
        let offered = try XCTUnwrap(rig.model.restoreOffer?.bench)

        rig.model.answer(.fresh)

        XCTAssertEqual(rig.server.verbs.map { $0["verb"] as? String }, ["workspace/reset"])
        XCTAssertNil(rig.model.restoreOffer)
        XCTAssertEqual(rig.model.bench?.panes.count, 1)
        XCTAssertEqual(
            rig.model.shelvedBench, offered,
            "one wrong click must not destroy a layout: fresh does not open it, it does not "
                + "forget it")
    }

    func testRestoringTheShelfIsAnUnshelve() throws {
        let rig = try showing(stored(terminals: 1), shelved: stored(terminals: 6))
        let declined = try XCTUnwrap(rig.model.shelvedBench)
        XCTAssertEqual(rig.model.restoreOffer?.bench, declined, "the question is about the shelf")

        rig.model.answer(.restore)

        XCTAssertEqual(rig.server.verbs.map { $0["verb"] as? String }, ["workspace/unshelve"])
        XCTAssertEqual(rig.model.bench, declined, "the shelf is what was offered, so it opens")
        XCTAssertNil(rig.model.shelvedBench, "and it is not shelved any more")
    }

    /// The other half: restoring the bench says nothing about an older declined one, and
    /// discarding it there would be the destruction the shelf exists to prevent, reached
    /// through the other button.
    func testRestoringTheBenchLeavesAnOlderShelfAlone() throws {
        let rig = try showing(stored(terminals: 2), shelved: stored(terminals: 6))
        let declined = try XCTUnwrap(rig.model.shelvedBench)

        rig.model.answer(.restore)

        XCTAssertTrue(rig.server.verbs.isEmpty)
        XCTAssertEqual(rig.model.bench?.panes.count, 2)
        XCTAssertEqual(rig.model.shelvedBench, declined, "one click must not destroy a layout")
    }

    // MARK: - What a reader outside the process sees

    /// An open question makes `columns` empty, and without a field saying so a reader could not
    /// tell that from a workspace helm simply has nothing for.
    func testAnOpenQuestionIsVisibleInTheSnapshotRatherThanLookingLikeAnEmptyHelm() throws {
        let rig = try showing(stored(terminals: 3, canvases: 1))
        let workspaces = WorkspaceModel()
        workspaces.follow(try XCTUnwrap(rig.model.document))

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: rig.model, terminals: rig.terminals
        ) { _ in nil }

        let record = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(record.state, .mounted)
        XCTAssertTrue(record.columns.isEmpty, "nothing is drawn while the question is open")
        XCTAssertEqual(record.awaitingRestore?.paneCount, 4, "and the reader is told why")
        XCTAssertEqual(record.awaitingRestore?.terminalCount, 3)
        XCTAssertEqual(record.awaitingRestore?.canvasCount, 1)
    }

    /// The control for the field: a workspace with its bench drawn must not carry one, or every
    /// reader learns to ignore it.
    func testADrawnBenchCarriesNoQuestion() throws {
        let rig = try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: stored(terminals: 2))],
                active: workspace.value))
        let workspaces = WorkspaceModel()
        workspaces.follow(try XCTUnwrap(rig.model.document))

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: rig.model, terminals: rig.terminals
        ) { _ in nil }

        XCTAssertNil(snapshot.workspaces.first?.awaitingRestore)
        XCTAssertEqual(snapshot.workspaces.first?.columns.count, 2)
    }

    /// With nothing open there is no bench to run a command on, and the refusal says so.
    func testABenchCommandWithNothingOpenStillSaysSo() throws {
        let rig = try toyRig(document: BenchDocument(workspaces: [], active: nil))
        let commander = WorkbenchSpoolCommander(workbench: rig.model, rail: ArchonRailModel())

        guard case let .failure(refusal) = commander.run(.newTerminal) else {
            return XCTFail("nothing is open")
        }

        XCTAssertTrue(refusal.reason.contains("no workspace open"))
    }

    /// A spool command while #85's question is open would reach benchd and change the bench the
    /// operator is being asked about (#453). It is refused naming the question, and nothing is
    /// sent.
    func testABenchCommandDuringTheQuestionIsRefusedAndSendsNothing() throws {
        let rig = try showing(stored(terminals: 3))
        XCTAssertNotNil(rig.model.restoreOffer)
        let commander = WorkbenchSpoolCommander(workbench: rig.model, rail: ArchonRailModel())

        guard case let .failure(refusal) = commander.run(.newTerminal) else {
            return XCTFail("the question is open")
        }

        XCTAssertTrue(refusal.reason.contains("whether to restore"), refusal.reason)
        XCTAssertTrue(rig.server.verbs.isEmpty, "nothing reached benchd")
    }

    // MARK: - A request from outside

    /// **The one place helm answers the operator's own question for them**, named rather than a
    /// side effect of `bench == nil`. It resolves rather than refusing, on #179's ruling: a spawn
    /// that blocked until a human clicked would be dead exactly when the spool is worth having.
    /// **Restore** rather than fresh is what keeps that from being destructive.
    func testARequestFromOutsideResolvesAnOpenQuestionByRestoring() throws {
        let rig = try showing(stored(terminals: 3))
        let offered = try XCTUnwrap(rig.model.restoreOffer?.bench)

        rig.model.mountWithoutAsking()

        XCTAssertNil(rig.model.restoreOffer)
        XCTAssertEqual(
            rig.model.bench, offered, "restore, never fresh — it is the answer that loses nothing")
        XCTAssertTrue(rig.server.verbs.isEmpty, "nothing was declined, so nothing is shelved")
    }

    /// When the offer came from the shelf, resolving it un-shelves it exactly as
    /// `answer(.restore)` does — the two are the same answer reached two ways.
    func testResolvingAShelvedOfferFromOutsideIsAnUnshelveToo() throws {
        let rig = try showing(stored(terminals: 1), shelved: stored(terminals: 6))
        let declined = try XCTUnwrap(rig.model.shelvedBench)

        rig.model.mountWithoutAsking()

        XCTAssertEqual(rig.server.verbs.map { $0["verb"] as? String }, ["workspace/unshelve"])
        XCTAssertEqual(rig.model.bench, declined)
        XCTAssertNil(rig.model.shelvedBench)
    }

    /// The control: with no question open it does nothing at all, so it cannot be reached for
    /// as a general "make sure there is a bench" hammer.
    func testResolvingWithNoQuestionOpenSendsNothing() throws {
        let rig = try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: stored(terminals: 2))],
                active: workspace.value))
        let before = rig.server.verbs.count

        rig.model.mountWithoutAsking()

        XCTAssertEqual(rig.server.verbs.count, before)
    }

    // MARK: - Controls
    //
    // These are what fail if the change overshoots into asking about workspaces that have
    // nothing to ask about, or asking again on every switch.

    func testAFirstVisitsOneShellIsDrawnWithNoQuestion() throws {
        let rig = try toyRig(workspace.value, answering: false)

        XCTAssertNil(rig.model.restoreOffer, "one empty shell asks nothing")
        XCTAssertEqual(rig.model.bench?.panes.count, 1)
        XCTAssertEqual(rig.terminals.sessions(for: workspace).count, 1)
    }

    /// #85 asks at the first showing, which is once per launch per workspace — not at every
    /// switch back.
    func testSwitchingBackToAnAnsweredWorkspaceDrawsItStraightAway() throws {
        let rig = try showing(stored(terminals: 3))
        rig.model.answer(.restore)
        let other = "/tmp/helm-bench-mount-other"

        rig.model.send(.workspaceOpen(path: other), by: .operatorGesture)
        rig.model.send(.workspaceActivate(path: workspace.value), by: .operatorGesture)

        XCTAssertEqual(rig.model.workspacePath, workspace)
        XCTAssertNil(rig.model.restoreOffer, "the question is asked once, not at every switch")
        XCTAssertEqual(rig.model.bench?.panes.count, 3)
    }
}
