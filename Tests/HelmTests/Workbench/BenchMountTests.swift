import HelmWire
import XCTest

@testable import Helm

/// #85: mounting a workspace offers restore or fresh instead of reopening the whole bench.
///
/// The ticket's own last acceptance line is what shapes this file — *"the decision logic is
/// reachable from `swift test`, not trapped in a `View`"* — so the first half runs against
/// `BenchMountPolicy` with no model at all, and the second half walks the operator's launch
/// through `WorkbenchModel` and the real store.
@MainActor
final class BenchMountTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-bench-mount")

    private func bench(terminals: Int, canvases: Int = 0) -> Workbench {
        var bench = Workbench(terminal: UUID())
        for _ in 1..<max(terminals, 1) {
            bench.insert(Pane(content: .terminal(face: .terminal)), at: .column)
        }
        for index in 0..<canvases {
            bench.insert(Pane(content: .canvas(.file("/tmp/a\(index).md"))), at: .column)
        }
        return bench
    }

    // MARK: - When the question is asked

    func testABenchWorthAskingAboutIsAskedAboutAndNamesItsPaneCount() throws {
        let saved = bench(terminals: 3, canvases: 2)

        guard case let .ask(offer) = BenchMountPolicy.mount(saved: saved, answered: false) else {
            return XCTFail("a five-pane bench must be offered, not reopened")
        }

        XCTAssertEqual(
            offer.paneCount, 5, "the count is the offer — it is what makes bloat visible")
        XCTAssertEqual(offer.terminalCount, 3)
        XCTAssertEqual(offer.canvasCount, 2)
        XCTAssertEqual(offer.bench, saved, "and answering restores exactly what was counted")
    }

    /// Restoring one empty shell and building one empty shell differ only in a uuid nobody can
    /// see, so a question there would be chrome with no decision under it.
    func testOneEmptyShellIsRestoredWithoutAsking() throws {
        let saved = bench(terminals: 1)

        guard case let .restore(restored) = BenchMountPolicy.mount(saved: saved, answered: false)
        else {
            return XCTFail("there is nothing to decide about a single empty shell")
        }

        XCTAssertEqual(
            restored, saved,
            "restore rather than fresh: the id is what TerminalManager rebuilds the row under")
    }

    /// The pane count is not the only thing that makes a bench worth asking about. A single
    /// pane whose whole value is the conversation it held is exactly the case #63 exists for.
    func testOnePaneStillAsksWhenItHeldAnAgent() throws {
        let pane = UUID()
        let saved = Workbench(
            panes: [
                Pane(
                    id: pane,
                    content: .terminal(
                        face: .terminal,
                        agent: ResumableAgent(command: "claude", session: "abc", cwd: "/tmp")))
            ])

        guard case let .ask(offer) = BenchMountPolicy.mount(saved: saved, answered: false) else {
            return XCTFail("a pane that held an agent is worth a question even on its own")
        }

        XCTAssertEqual(offer.paneCount, 1)
        XCTAssertEqual(offer.agentCount, 1, "and the offer says what declining costs")
    }

    func testNothingSavedIsFresh() {
        XCTAssertEqual(BenchMountPolicy.mount(saved: nil, answered: false), .fresh)
    }

    /// A workspace switch re-mounts. Re-asking on every switch would make the question chrome
    /// rather than a decision — #85 asks it *at mount*, which is once per launch per workspace.
    func testAWorkspaceAlreadyAnsweredThisLaunchIsNotAskedAgain() throws {
        let saved = bench(terminals: 4)

        guard case let .restore(restored) = BenchMountPolicy.mount(saved: saved, answered: true)
        else {
            return XCTFail("switching back to a workspace must not re-open its question")
        }

        XCTAssertEqual(restored, saved)
    }

    // MARK: - The shelf

    /// *"Fresh means do not open it now, never forget it."* The declined bench is offered
    /// again while the saved one is still the throwaway shell that replaced it.
    func testAShelvedBenchIsOfferedBackWhileTheSavedOneIsStillTheFreshShell() throws {
        let declined = bench(terminals: 6)

        guard
            case let .ask(offer) = BenchMountPolicy.mount(
                saved: bench(terminals: 1), shelved: declined, answered: false)
        else {
            return XCTFail("a declined bench must still be reachable")
        }

        XCTAssertEqual(offer.bench, declined, "the question is about what was declined")
        XCTAssertEqual(offer.paneCount, 6)
    }

    /// …and it stops offering itself as soon as the operator has built something worth saving,
    /// so a decline does not turn into a nag.
    func testTheShelfStopsBeingOfferedOnceTheLiveBenchIsWorthSomething() throws {
        let declined = bench(terminals: 6)
        let worked = bench(terminals: 2)

        guard
            case let .ask(offer) = BenchMountPolicy.mount(
                saved: worked, shelved: declined, answered: false)
        else {
            return XCTFail("a two-pane bench is still worth a question")
        }

        XCTAssertEqual(
            offer.bench, worked,
            "the question is about the bench the operator actually left, not the old shelf")
    }

    // MARK: - The model, and what happens while the question is open

    func testWhileTheQuestionIsOpenNothingIsMountedAndNoShellIsSpawned() throws {
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)

        model.activate(workspacePath: workspace, offering: bench(terminals: 3))

        XCTAssertNotNil(model.restoreOffer, "the question is open")
        XCTAssertNil(model.bench, "and nothing is mounted behind it")
        XCTAssertTrue(
            terminals.sessions(for: workspace).isEmpty,
            "a question that has already spawned the thing it asks about is not a question")
    }

    /// The saved bench survives an unanswered question, which is what makes declining safe:
    /// `WorkspaceModel.saveContext` returns early on a nil bench, so nothing is written over it.
    func testAnUnansweredQuestionWritesNothingOverTheSavedBench() throws {
        let defaults = try isolatedDefaults("bench-mount-unanswered")
        let saved = bench(terminals: 4)
        let workspaces = WorkspaceModel(defaults: defaults)
        let workspace = Workspace(path: "/tmp/helm-bench-mount-unanswered")
        workspaces.open(workspace)
        WorkspaceContextStore.save(
            [workspace.path.value: WorkspaceContext(workbench: saved)], to: defaults)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)

        model.activate(workspacePath: workspace.path, offering: saved)
        workspaces.saveContext(terminalManager: terminals, workbench: model)

        XCTAssertEqual(
            WorkspaceContextStore.load(from: defaults)[workspace.path.value]?.workbench, saved,
            "an open question must not cost the bench it is asking about")
    }

    func testRestoringMountsExactlyWhatWasOffered() throws {
        let saved = bench(terminals: 3)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, offering: saved)

        model.answer(.restore)

        XCTAssertNil(model.restoreOffer)
        XCTAssertEqual(model.bench, saved)
        XCTAssertEqual(
            terminals.sessions(for: workspace).map(\.id), saved.terminalPaneIDs,
            "the terminals come back under their persisted ids")
        XCTAssertNil(model.shelvedBench, "a bench that was opened is not shelved")
    }

    func testFreshYieldsOneShellAndShelvesWhatItDeclined() throws {
        let saved = bench(terminals: 4)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, offering: saved)

        model.answer(.fresh)

        XCTAssertNil(model.restoreOffer)
        XCTAssertEqual(model.bench?.panes.count, 1, "fresh is one shell — defaultBench as it was")
        XCTAssertEqual(
            model.shelvedBench, saved,
            "one wrong click must not destroy a layout: fresh does not open it, it does not "
                + "forget it")
    }

    /// The whole point of the shelf, walked end to end: decline, let the save path run, and
    /// read the store back.
    func testAShelvedBenchSurvivesTheSaveThatOverwritesTheLiveOne() throws {
        let defaults = try isolatedDefaults("bench-mount-shelf")
        let workspace = Workspace(path: "/tmp/helm-bench-mount-shelf")
        let saved = bench(terminals: 5, canvases: 1)
        let workspaces = WorkspaceModel(defaults: defaults)
        workspaces.open(workspace)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace.path, offering: saved)

        model.answer(.fresh)
        workspaces.saveContext(terminalManager: terminals, workbench: model)

        let context = try XCTUnwrap(
            WorkspaceContextStore.load(from: defaults)[workspace.path.value])
        XCTAssertEqual(context.workbench?.panes.count, 1, "the fresh shell is what is live now")
        XCTAssertEqual(context.shelvedBench, saved, "and the declined bench is still on disk")
    }

    func testRestoringTheShelfIsWhatStopsItBeingShelved() throws {
        let declined = bench(terminals: 6)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(
            workspacePath: workspace, offering: bench(terminals: 1), shelved: declined)

        model.answer(.restore)

        XCTAssertEqual(model.bench, declined, "the shelf is what was offered, so it is what opens")
        XCTAssertNil(model.shelvedBench, "and it is not shelved any more")
    }

    /// The other half: restoring the *saved* bench says nothing about an older declined one,
    /// and discarding it there would be the destruction the shelf exists to prevent, reached
    /// through the other button.
    func testRestoringTheSavedBenchLeavesAnOlderShelfAlone() throws {
        let declined = bench(terminals: 6)
        let worked = bench(terminals: 2)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, offering: worked, shelved: declined)

        model.answer(.restore)

        XCTAssertEqual(model.bench, worked)
        XCTAssertEqual(model.shelvedBench, declined, "one click must not destroy a layout")
    }

    // MARK: - What a reader outside the process sees

    /// An open question makes `columns` empty, and without a field saying so a reader could not
    /// tell that from a workspace helm simply has nothing for.
    func testAnOpenQuestionIsVisibleInTheSnapshotRatherThanLookingLikeAnEmptyHelm() throws {
        let workspace = Workspace(path: "/tmp/helm-bench-mount-snapshot")
        let workspaces = WorkspaceModel(defaults: try isolatedDefaults("bench-mount-snapshot"))
        workspaces.open(workspace)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace.path, offering: bench(terminals: 3, canvases: 1))

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: model, terminals: terminals,
            addressBook: AddressBook(owners: [], sessionFor: { _ in nil })
        ) { _ in nil }

        let record = try XCTUnwrap(snapshot.workspaces.first)
        XCTAssertEqual(record.state, .mounted)
        XCTAssertTrue(record.columns.isEmpty, "nothing is built while the question is open")
        XCTAssertEqual(record.awaitingRestore?.paneCount, 4, "and the reader is told why")
        XCTAssertEqual(record.awaitingRestore?.terminalCount, 3)
        XCTAssertEqual(record.awaitingRestore?.canvasCount, 1)
    }

    /// The control for the field: a mounted workspace with a bench must not carry one, or
    /// every reader learns to ignore it.
    func testAMountedBenchCarriesNoQuestion() throws {
        let workspace = Workspace(path: "/tmp/helm-bench-mount-snapshot-answered")
        let workspaces = WorkspaceModel(
            defaults: try isolatedDefaults("bench-mount-snapshot-answered"))
        workspaces.open(workspace)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace.path, restoring: bench(terminals: 2))

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: model, terminals: terminals,
            addressBook: AddressBook(owners: [], sessionFor: { _ in nil })
        ) { _ in nil }

        XCTAssertNil(snapshot.workspaces.first?.awaitingRestore)
        XCTAssertEqual(snapshot.workspaces.first?.columns.count, 2)
    }

    /// **Measured live against a real restart before it was written.** An agent sending
    /// `newTerminal` while the question was open was told *"helm has no workspace open… open
    /// one"* about a workspace that was open, and the only thing it could do with that advice
    /// was ask helm to open it again.
    func testABenchCommandSentWhileTheQuestionIsOpenIsRefusedWithTheRightReason() throws {
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        let commander = WorkbenchSpoolCommander(workbench: model, rail: ArchonRailModel())
        model.activate(workspacePath: workspace, offering: bench(terminals: 7))

        guard case let .failure(refusal) = commander.run(.newTerminal) else {
            return XCTFail("there is no bench to run a command on")
        }

        XCTAssertTrue(
            refusal.reason.contains("7 saved pane"),
            "the refusal names what is actually being asked: \(refusal.reason)")
        XCTAssertFalse(
            refusal.reason.contains("no workspace open"),
            "a workspace IS open — it is waiting on an answer")
    }

    /// The control: with genuinely nothing open, the message is the one it always was.
    func testABenchCommandWithNothingOpenStillSaysSo() throws {
        let model = WorkbenchModel(terminals: TerminalManager(), agents: .blind)
        let commander = WorkbenchSpoolCommander(workbench: model, rail: ArchonRailModel())

        guard case let .failure(refusal) = commander.run(.newTerminal) else {
            return XCTFail("nothing is open")
        }

        XCTAssertTrue(refusal.reason.contains("no workspace open"))
    }

    // MARK: - The mount that never asks

    /// **The regression `BenchMountPolicy`'s header records.** A spool spawn's `cwd` becomes a
    /// workspace, and the spool exists for the case where nobody is at the pane — so a question
    /// raised there would be #179's silent hang with a different cause, and the spawn would
    /// fail against a bench that was never built.
    func testTheNonAskingMountRestoresWithoutRaisingAQuestion() throws {
        let saved = bench(terminals: 4)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)

        model.activate(workspacePath: workspace, restoring: saved)

        XCTAssertNil(model.restoreOffer, "nobody is at the pane to answer one")
        XCTAssertEqual(model.bench, saved)
        XCTAssertNotNil(
            model.spawnTerminal(), "and a spawn into it has a bench to land on")
    }

    /// **The one place helm answers the operator's own question for them**, and it is named
    /// rather than a side effect of `bench == nil` — which is how it reached this state in the
    /// first draft, with no code path saying so and no test measuring it.
    ///
    /// It resolves rather than refusing, on #179's ruling: a spawn that blocked until a human
    /// clicked would be dead exactly when the spool is worth having. **Restore** rather than
    /// fresh is what keeps that from being destructive.
    func testARequestFromOutsideResolvesAnOpenQuestionByRestoring() throws {
        let saved = bench(terminals: 3)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, offering: saved)
        XCTAssertNotNil(model.restoreOffer, "the question is open on the operator's screen")

        model.mountWithoutAsking()

        XCTAssertNil(model.restoreOffer)
        XCTAssertEqual(
            model.bench, saved, "restore, never fresh — it is the answer that loses nothing")
        XCTAssertNil(model.shelvedBench, "and nothing was declined, so nothing is shelved")
    }

    /// The control: with no question open it does nothing at all, so it cannot be reached for
    /// as a general "make sure there is a bench" hammer.
    func testResolvingWithNoQuestionOpenChangesNothing() throws {
        let saved = bench(terminals: 2)
        let model = WorkbenchModel(terminals: TerminalManager(), agents: .blind)
        model.activate(workspacePath: workspace, restoring: saved)

        model.mountWithoutAsking()

        XCTAssertEqual(model.bench, saved)
    }

    // MARK: - Controls
    //
    // Both of these pass on `origin/development` too, and are here as controls: the change
    // could satisfy every assertion above by simply asking less, and these are what fail if it
    // overshoots into asking about workspaces that have nothing to ask about.

    func testAFirstVisitStillGetsTodaysOneByOneFrameWithNoQuestion() throws {
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)

        model.activate(workspacePath: workspace, offering: nil)

        XCTAssertNil(model.restoreOffer, "a workspace with nothing persisted asks nothing")
        XCTAssertEqual(model.bench?.panes.count, 1)
        XCTAssertEqual(terminals.sessions(for: workspace).count, 1)
    }

    func testSwitchingBackToAnAnsweredWorkspaceMountsStraightAway() throws {
        let saved = bench(terminals: 3)
        let other = WorkspacePath("/tmp/helm-bench-mount-other")
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind)
        model.activate(workspacePath: workspace, offering: saved)
        model.answer(.restore)

        model.activate(workspacePath: other, offering: nil)
        model.activate(workspacePath: workspace, offering: saved)

        XCTAssertNil(model.restoreOffer, "the question is asked at mount, not at every switch")
        XCTAssertEqual(model.bench, saved)
    }
}
