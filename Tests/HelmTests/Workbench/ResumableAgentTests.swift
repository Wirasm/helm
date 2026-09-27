import HelmWire
import XCTest

@testable import Helm

/// #63: the agent a pane held is recorded on the bench, which is what `bench restore` resumes
/// there after benchd restarts (M5b, `just resume-all`). The offer to resume it in helm is gone
/// with #85's question.
@MainActor
final class ResumableAgentTests: XCTestCase {
    private let workspace = WorkspacePath("/tmp/helm-resume")

    private func agent(
        _ session: String = "4f2a1b3c-0000-1111-2222-333344445555",
        command: String = "claude",
        cwd: String = "/tmp/helm-resume"
    ) -> ResumableAgent {
        ResumableAgent(command: command, session: session, cwd: cwd)
    }

    private func row(pid: pid_t, session: String, cwd: String?) -> AgentSession {
        AgentSession(pid: pid, cwd: cwd, status: .busy, sessionId: session)
    }

    /// helm drawn from a toy benchd holding one workspace with `panes` as tabs.
    private func rig(_ panes: [BenchDocument.Pane], agents: AgentObserver) throws -> ToyRig {
        try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: ToyBench.bench(panes))],
                active: workspace.value)
        ) { terminals, client in
            WorkbenchModel(terminals: terminals, agents: agents, client: client)
        }
    }

    private func holding(_ agent: ResumableAgent?, id: UUID = UUID()) -> BenchDocument.Pane {
        .init(id: id, surface: .terminal(agent: agent.map(BenchDocument.Agent.init)))
    }

    // MARK: - The record, and that it survives a relaunch

    /// The whole of #63's persistence: without this the offer has nothing to be about. benchd
    /// keeps the record in its document, and helm reads it back out of every document.
    func testTheAgentOnAPaneSurvivesTheDocument() throws {
        let pane = UUID()
        let restored = try XCTUnwrap(
            Workbench(document: BenchFixture.bench([holding(agent(), id: pane)])))

        XCTAssertEqual(
            restored.pane(pane)?.content, .terminal(agent: agent()),
            "the pty died with the process; the id of the conversation it held did not")
    }

    // MARK: - Watching the panes

    func testAnAgentSeenInAPaneIsSentToBenchdAsHelmsRecord() throws {
        let pane = UUID()
        let rig = try rig(
            [holding(nil, id: pane)],
            agents: .fixture(
                foreground: [pane: 4242],
                rows: [4242: row(pid: 4242, session: "abc", cwd: "/tmp/sub")]))

        rig.model.observeAgents()

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/record")
        XCTAssertEqual((sent["by"] as? [String: Any])?["kind"] as? String, "helm")
        XCTAssertEqual(
            rig.model.bench?.pane(pane)?.content,
            .terminal(
                agent: ResumableAgent(command: "claude", session: "abc", cwd: "/tmp/sub")),
            "the registry's own cwd, because an agent started in a subdirectory is not "
                + "working in the workspace root")
    }

    /// **The record is sticky**, and this is the case that decides it: a `claude` running a
    /// bash command hands the pty's foreground to a child, so a record cleared on absence
    /// would be erased and rewritten several times a minute — and would be *absent* if helm
    /// died inside one of those windows, which is the crash #63 exists for.
    func testARecordIsNotErasedWhenTheAgentStopsBeingTheForegroundProcess() throws {
        let pane = UUID()
        let rig = try rig([holding(agent("abc"), id: pane)], agents: .blind)
        let before = rig.server.verbs.count

        rig.model.observeAgents()

        XCTAssertEqual(rig.server.verbs.count, before, "nothing is sent about an agent not seen")
        XCTAssertEqual(
            rig.model.bench?.resumableAgents.map(\.agent.session), ["abc"],
            "what was running here is still what was running here")
    }

    /// Only a change is sent: the same record every two seconds would be an event per tick in
    /// benchd's log for the life of the process.
    func testAnAgentAlreadyRecordedIsNotSentAgain() throws {
        let pane = UUID()
        let rig = try rig(
            [holding(agent("abc", cwd: "/tmp/sub"), id: pane)],
            agents: .fixture(
                foreground: [pane: 4242],
                rows: [4242: row(pid: 4242, session: "abc", cwd: "/tmp/sub")]))

        rig.model.observeAgents()

        XCTAssertTrue(rig.server.verbs.isEmpty)
    }

    // MARK: - What a reader outside the process sees

    /// The control: a pane with nothing recorded carries no key at all, on a bench that is
    /// otherwise identical. It is what fails if the field is written unconditionally.
    func testAPaneThatNeverHeldAnAgentCarriesNoResumeRecord() throws {
        let pane = UUID()
        let snapshot = try project(
            bench: BenchFixture.bench([holding(nil, id: pane)]))

        XCTAssertNil(try panes(in: snapshot)[pane]?.resumable)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot))
                as? [String: Any])
        XCTAssertFalse(
            String(describing: json).contains("resumable"),
            "an absent record is an absent key, not a null one")
    }

    /// A background workspace still says what its panes were holding: the record is on the
    /// bench, in benchd's document, not in anything helm holds for the workspace on screen.
    func testABackgroundWorkspaceStillReportsWhatItsPanesHeld()
        throws
    {
        let parked = Workspace(path: "/tmp/helm-resume-parked")
        let mounted = Workspace(path: "/tmp/helm-resume-mounted")
        let rig = try toyRig(
            document: BenchDocument(
                workspaces: [
                    .init(path: parked.path.value, bench: ToyBench.bench([holding(agent())])),
                    .init(path: mounted.path.value, bench: ToyBench.bench([ToyBench.terminal()])),
                ], active: mounted.path.value)
        ) { terminals, client in
            WorkbenchModel(
                terminals: terminals, agents: .fixture(foreground: [:], rows: [:]),
                client: client)
        }
        let workspaces = WorkspaceModel()
        workspaces.follow(try XCTUnwrap(rig.model.document))

        let snapshot = BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: rig.model, terminals: rig.terminals
        ) { _ in nil }

        let record = try XCTUnwrap(snapshot.workspaces.first { $0.path == parked.path })
        XCTAssertEqual(record.state, .parked)
        let resumable = try XCTUnwrap(
            record.columns.flatMap(\.slots).flatMap(\.panes).first?.terminal?.resumable,
            "the record is on the bench, so a workspace in the background still has it")
        XCTAssertEqual(resumable.session, agent().session)
    }

    private func project(
        bench: BenchDocument.Bench
    ) throws -> BenchSnapshot {
        let rig = try toyRig(
            document: BenchDocument(
                workspaces: [.init(path: workspace.value, bench: bench)],
                active: workspace.value)
        ) { terminals, client in
            WorkbenchModel(
                terminals: terminals,
                agents: .fixture(foreground: [:], rows: [:]), client: client)
        }
        let workspaces = WorkspaceModel()
        workspaces.follow(try XCTUnwrap(rig.model.document))
        return BenchSnapshot.project(
            writtenAt: Date(timeIntervalSince1970: 42), workspaces: workspaces,
            workbench: rig.model, terminals: rig.terminals
        ) { _ in nil }
    }

    private func panes(in snapshot: BenchSnapshot) throws -> [UUID: BenchSnapshot.TerminalRecord] {
        let record = try XCTUnwrap(snapshot.workspaces.first)
        return Dictionary(
            record.columns.flatMap(\.slots).flatMap(\.panes)
                .compactMap { pane in pane.terminal.map { (pane.id, $0) } },
            uniquingKeysWith: { first, _ in first })
    }
}
