import Foundation
import HelmWire
import XCTest

@testable import Helm

/// helm drawn from benchd, against the stand-in: every gesture goes out as a verb, and nothing
/// changes on screen until a document says so.
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
        let model = WorkbenchModel(terminals: terminals, agents: .blind, client: client)
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
        // The workspace list follows the document, as `RootView` wires it.
        let workspaces = WorkspaceModel()
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

    /// A pane moved into a drawer (#356) is still in the document, so its live object stays:
    /// only a pane in no workspace and no drawer has been closed.
    func testAPaneMovedIntoADrawerKeepsItsSession() throws {
        let first = UUID()
        let second = UUID()
        let rig = try rig(
            BenchFixture.document(
                path,
                BenchFixture.bench([BenchFixture.terminal(first), BenchFixture.terminal(second)]),
                seq: 1))
        XCTAssertTrue(Eventually.holds { rig.terminals.sessions.count == 2 })

        var moved = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 2)
        moved.document.drawers = [
            .init(name: "scratch", panes: [BenchFixture.terminal(second)], selected: second)
        ]
        rig.server.push(moved)

        XCTAssertTrue(Eventually.holds { rig.model.bench?.panes.count == 1 })
        XCTAssertEqual(Set(rig.terminals.sessions.map(\.id)), [first, second])
    }

    /// A background workspace's terminals get their sessions when it is shown, not before: a
    /// pty starts only once its pane is drawn, so a session made earlier would hold nothing.
    func testABackgroundWorkspacesTerminalsStartWhenItIsShown() throws {
        let first = UUID()
        let other = "/tmp/helm-client-mode-other"
        let waiting = UUID()
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 1))
        rig.server.push(
            BenchFixture.document(
                path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 2,
                others: [
                    .init(path: other, bench: BenchFixture.bench([BenchFixture.terminal(waiting)]))
                ]))
        XCTAssertTrue(Eventually.holds { rig.model.document?.workspaces.count == 2 })
        XCTAssertFalse(rig.terminals.sessions.contains { $0.id == waiting })

        var shown = BenchFixture.document(
            path, BenchFixture.bench([BenchFixture.terminal(first)]), seq: 3,
            others: [
                .init(path: other, bench: BenchFixture.bench([BenchFixture.terminal(waiting)]))
            ])
        shown.document.active = other
        rig.server.push(shown)

        XCTAssertTrue(Eventually.holds { rig.terminals.sessions.contains { $0.id == waiting } })
        XCTAssertEqual(
            rig.terminals.sessions.first { $0.id == waiting }?.workspacePath, WorkspacePath(other))
    }

    /// **The import's first document starts nothing it has not been asked to.** benchd's first
    /// document is empty and the import fills it, so every workspace is new at once; starting
    /// their terminals as arrivals would spawn the very shells #85's question is about to ask
    /// whether to restore. Measured against a live import before this was written.
    func testTheDocumentAfterAnEmptyOneStartsNoShellBehindAnOpenQuestion() throws {
        let rig = try rig(
            DocumentAt(seq: 1, document: BenchDocument(workspaces: [], active: nil)),
            restoring: false)
        let panes = (0..<3).map { _ in BenchFixture.terminal() }

        rig.server.push(
            BenchFixture.document(
                path, BenchFixture.bench(panes), seq: 2,
                others: [
                    .init(
                        path: "/tmp/helm-client-mode-other",
                        bench: BenchFixture.bench([BenchFixture.terminal()]))
                ]))

        XCTAssertTrue(Eventually.holds { rig.model.restoreOffer != nil }, "three panes ask")
        XCTAssertTrue(
            rig.terminals.sessions.isEmpty,
            "nothing is spawned while the question is open, nor in a workspace not yet shown")
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

    /// The placeholder keeps its kind's name everywhere it is written down: in a saved bench,
    /// and in `snapshot.json`, which is how an agent without a display reads the bench.
    func testAPlaceholderKeepsItsKindInTheSnapshotAndThroughCodable() throws {
        let pane = Pane(content: .unsupported("whiteboard"))
        let decoded = try JSONDecoder().decode(Pane.self, from: JSONEncoder().encode(pane))
        XCTAssertEqual(decoded, pane)

        let record = BenchSnapshot.PaneRecord(
            pane: pane, selected: true, visible: true, focused: false, live: nil,
            foregroundPid: { _ in nil }, agents: [:])
        XCTAssertEqual(record.kind, .unsupported)
        XCTAssertEqual(record.unsupportedKind, "whiteboard")
    }

    /// #85's question stays helm's (D4): a bench worth asking about is not drawn until
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

    /// A "fresh" benchd refuses leaves the question open rather than mounting the bench the
    /// operator declined.
    func testARefusedResetLeavesTheRestoreQuestionOpen() throws {
        let panes = (0..<3).map { _ in BenchFixture.terminal() }
        let rig = try rig(
            BenchFixture.document(path, BenchFixture.bench(panes), seq: 1), restoring: false)
        rig.server.answer = { request in
            ["id": request["id"] ?? "", "status": "refused", "reason": "not now"]
        }

        rig.model.answer(.fresh)

        XCTAssertNotNil(rig.model.restoreOffer, "the choice did not happen, so it is still asked")
        XCTAssertNil(rig.model.bench)
        XCTAssertTrue(rig.terminals.sessions.isEmpty)
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
