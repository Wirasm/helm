import Foundation
import HelmWire
import XCTest

@testable import Helm

/// helm drawn from benchd (`HELM_BENCH=daemon`), against the stand-in: every gesture goes out as
/// a verb, and nothing changes on screen until a document says so.
///
/// The local-mode suites are the control: they run the same model with `LocalSink`, unchanged.
@MainActor
final class WorkbenchClientModeTests: XCTestCase {
    private let path = "/tmp/helm-client-mode"

    private struct Rig {
        let server: FakeBenchd
        let client: BenchClient
        let model: WorkbenchModel
        let terminals: TerminalManager
    }

    /// `restoring` answers #85's question when the first bench is worth asking about, which is
    /// what the operator does before anything else on a restored bench.
    private func rig(_ first: DocumentAt, restoring: Bool = true) throws -> Rig {
        let server = try FakeBenchd(document: first)
        let client = BenchClient(socketPath: server.path)
        let terminals = TerminalManager()
        let model = WorkbenchModel(terminals: terminals, agents: .blind, mode: .daemon(client))
        addTeardownBlock { @MainActor in
            client.stop()
            server.stop()
        }
        XCTAssertTrue(Eventually.holds { model.document != nil }, "the first document never came")
        if restoring, model.restoreOffer != nil { model.answer(.restore) }
        return Rig(server: server, client: client, model: model, terminals: terminals)
    }

    private func by(_ request: [String: Any]) -> String? {
        (request["by"] as? [String: Any])?["kind"] as? String
    }

    /// Every key in the table that is a bench gesture goes to benchd as the operator's verb.
    func testEachBindingsVerbIsSentAsTheOperator() throws {
        let first = UUID()
        let second = UUID()
        let rig = try rig(
            BenchFixture.document(
                path,
                BenchFixture.bench([BenchFixture.terminal(first), BenchFixture.terminal(second)]),
                seq: 1))
        let defaults = try isolatedDefaults("client-mode-keys")
        // The workspace list follows the document, as `RootView` wires it in daemon mode.
        let workspaces = WorkspaceModel(defaults: defaults)
        workspaces.follow(try XCTUnwrap(rig.model.document))
        let actions = LocalActions(
            workbench: rig.model, workspaces: workspaces,
            rail: ArchonRailModel(client: FakeArchonClient(), defaults: defaults),
            terminals: rig.terminals)
        let gestures = KeyBindings.all.compactMap { row -> KeyBinding.Action? in
            guard case .verb(let template) = row.action else { return nil }
            // Only the gestures that mean something on a one-workspace bench.
            if case .activateWorkspace(let index) = template, index > 0 { return nil }
            if case .showTab(let index) = template, index > 1 { return nil }
            return row.action
        }
        XCTAssertFalse(gestures.isEmpty)

        for gesture in gestures { actions.perform(gesture) }

        let sent = rig.server.verbs
        XCTAssertEqual(
            sent.count, gestures.count, "one verb per gesture: \(sent.map { $0["verb"] ?? "" })")
        for request in sent {
            XCTAssertEqual(
                by(request), "operator",
                "\(request["verb"] ?? "") went as \(by(request) ?? "nobody")")
        }
        XCTAssertEqual(
            rig.model.document?.workspaces.count, 1, "nothing was drawn that benchd did not send")
    }

    /// A follower wired after benchd first answered still gets that document: `RootView` wires
    /// its follower in `.task`, which the client's first document usually beats.
    func testAFollowerSetLateGetsTheDocumentAlreadyDrawn() throws {
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        var followed: [BenchDocument] = []

        rig.model.followDocuments { followed.append($0) }

        XCTAssertEqual(followed.map(\.workspaces.count), [1])
    }

    /// A frame is what moves the bench: its active workspace's bench is drawn, and what is on
    /// screen follows it.
    func testAFrameDrivesTheBenchAndWhatIsVisible() throws {
        let first = UUID()
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 1))
        XCTAssertEqual(rig.model.bench?.panes.map(\.id), [first])

        let second = UUID()
        rig.server.push(
            BenchFixture.document(
                path,
                BenchFixture.bench(
                    [BenchFixture.terminal(first), BenchFixture.terminal(second)], selected: second),
                seq: 2))

        XCTAssertTrue(Eventually.holds { rig.model.bench?.panes.count == 2 })
        XCTAssertEqual(rig.model.bench?.visiblePaneIDs, [second])
        XCTAssertEqual(rig.model.workspacePath, WorkspacePath(path))
    }

    /// A terminal in a frame gets exactly one session, and leaving the document closes it.
    func testATerminalInAFrameIsOneSessionAndItsRemovalClosesIt() throws {
        let first = UUID()
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 1))
        let second = UUID()
        let both = BenchFixture.bench([BenchFixture.terminal(first), BenchFixture.terminal(second)])
        rig.server.push(BenchFixture.document(path, both, seq: 2))
        rig.server.push(BenchFixture.document(path, both, seq: 3))

        XCTAssertTrue(Eventually.holds { rig.terminals.sessions.count == 2 })
        XCTAssertEqual(
            Set(rig.terminals.sessions.map(\.id)), [first, second],
            "one session per pane, the pane's id")

        rig.server.push(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 4))
        XCTAssertTrue(
            Eventually.holds { rig.terminals.sessions.map(\.id) == [first] },
            "the closed pane's session went")
    }

    /// A terminal an agent opens in a workspace that is not on screen starts at once, so a spawn
    /// there has a shell to type into — and the operator's view stays where it was.
    func testATerminalThatArrivesInABackgroundWorkspaceStartsThere() throws {
        let first = UUID()
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 1))
        let spawned = UUID()
        rig.server.push(
            BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 2,
                others: [
                    .init(
                        path: "/tmp/helm-client-mode-other",
                        bench: BenchFixture.bench([BenchFixture.terminal(spawned)]))
                ]))

        XCTAssertTrue(Eventually.holds { rig.terminals.sessions.contains { $0.id == spawned } })
        XCTAssertEqual(
            rig.terminals.sessions.first { $0.id == spawned }?.workspacePath,
            WorkspacePath("/tmp/helm-client-mode-other"))
        XCTAssertEqual(rig.model.workspacePath, WorkspacePath(path), "the view did not move")
    }

    /// The spool's `select` is an agent's verb, and the result it reports is read back off the
    /// document benchd sent — not off anything helm changed itself.
    func testASpoolSelectIsSentAsAnAgentAndReportsTheDocument() throws {
        let first = UUID()
        let hidden = UUID()
        let path = self.path
        let rig = try rig(
            BenchFixture.document(
                path,
                BenchFixture.bench([BenchFixture.terminal(first), BenchFixture.terminal(hidden)]),
                seq: 1))
        rig.server.answerWith { _ in
            BenchFixture.document(
                path,
                BenchFixture.bench(
                    [BenchFixture.terminal(first), BenchFixture.terminal(hidden)], selected: hidden),
                seq: 2)
        }
        let panes = WorkbenchSpoolPanes(workbench: rig.model, terminals: rig.terminals)

        let report = try panes.select(hidden).get()

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "pane/show")
        XCTAssertEqual(by(sent), "agent")
        XCTAssertTrue(report.isVisible, "read back off the frame benchd pushed before answering")
    }

    /// A kind this build does not know keeps its pane, with a placeholder where it is.
    func testAnUnknownKindIsAPlaceholderNotALostPane() throws {
        let whiteboard = UUID()
        let rig = try rig(
            BenchFixture.document(
                path,
                BenchFixture.bench([
                    BenchFixture.terminal(),
                    .init(id: whiteboard, surface: .unsupported(kind: "whiteboard")),
                ]),
                seq: 1))

        let pane = try XCTUnwrap(rig.model.bench?.pane(whiteboard))
        XCTAssertEqual(pane.content, .unsupported("whiteboard"))
        let slot = try XCTUnwrap(rig.model.bench?.slot(for: whiteboard))
        XCTAssertNotNil(
            rig.model.surfaceView(of: pane, in: rig.model.surfaceSlot(for: pane, in: slot)))
    }

    /// #85's question stays helm's in daemon mode: a bench worth asking about is not drawn until
    /// the operator answers, and "fresh" goes to benchd as `workspace/reset`.
    func testTheRestoreQuestionIsAskedAndFreshIsAReset() throws {
        let panes = (0..<3).map { _ in BenchFixture.terminal() }
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench(panes), seq: 1), restoring: false)

        XCTAssertNotNil(rig.model.restoreOffer, "three saved panes are worth asking about")
        XCTAssertTrue(
            rig.terminals.sessions.isEmpty, "nothing is spawned while the question is open")

        rig.model.answer(.fresh)

        let sent = try XCTUnwrap(rig.server.verbs.last)
        XCTAssertEqual(sent["verb"] as? String, "workspace/reset")
        XCTAssertEqual(by(sent), "operator")
    }

    /// A divider drag is drawn as it moves and reaches benchd once, on release — not as a
    /// hundred events in the log for one gesture.
    func testADividerDragIsSentOnceOnRelease() throws {
        let first = UUID()
        let second = UUID()
        let slot = UUID()
        let other = UUID()
        let left = UUID()
        let right = UUID()
        let bench = BenchDocument.Bench(
            columns: [
                .init(
                    id: left,
                    slots: [
                        .init(
                            id: slot, panes: [BenchFixture.terminal(first)], selected: first,
                            height: 1)
                    ], width: 0.5),
                .init(
                    id: right,
                    slots: [
                        .init(
                            id: other, panes: [BenchFixture.terminal(second)], selected: second,
                            height: 1)
                    ], width: 0.5),
            ],
            focusedSlot: slot)
        let rig = try rig(BenchFixture.document(path, bench, seq: 1))

        for fraction in [0.55, 0.6, 0.65] {
            rig.model.resize(.columns(member: left, against: right), to: fraction, released: false)
        }
        XCTAssertEqual(
            rig.model.bench?.columns.first?.width ?? 0, 0.65, accuracy: 0.001, "drawn as it moves")
        XCTAssertTrue(rig.server.verbs.isEmpty, "nothing sent while the drag moves")

        rig.model.resize(.columns(member: left, against: right), to: 0.7, released: true)

        XCTAssertEqual(rig.server.verbs.map { $0["verb"] as? String }, ["layout/resize"])
        let args = try XCTUnwrap(rig.server.verbs.first?["args"] as? [String: Any])
        XCTAssertEqual(args["fraction"] as? Double, 0.7)
    }

    /// While benchd is down a verb fails where the operator can see it, and nothing moves.
    func testAVerbWithBenchdGoneFailsVisiblyAndChangesNothing() throws {
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal()]), seq: 1))
        let before = rig.model.bench
        rig.server.stop()

        XCTAssertNil(rig.model.send(.paneSplit(direction: .right), by: .operatorGesture))

        XCTAssertNotNil(rig.model.verbFailure)
        XCTAssertEqual(
            rig.model.bench, before, "the last document stays, and nothing local happens")
        XCTAssertTrue(
            Eventually.holds { if case .disconnected = rig.client.state { true } else { false } })
    }
}
