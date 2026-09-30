import HelmWire
import XCTest

@testable import Helm

/// "Ask a fork" (#535) through the real path: an agent opens a canvas, the operator marks a
/// passage and asks, and helm sends benchd one `spawn` of a read-only fork of the conversation
/// benchd recorded as the canvas's author. benchd is the toy, with `spawn` answered here, so what
/// is asserted is what helm sent. That the author survives a `/clear` is benchd's, and tested in
/// its conformance suite.
@MainActor
final class WorkbenchAskForkTests: XCTestCase {
    private var artifacts: URL!
    private var canvas: URL!
    private var copied: [String] = []
    /// The bench the canvas is on. Held because a canvas's routes hold it weakly.
    private var bench: WorkbenchModel?
    private let workspace = "/tmp/helm-ask-fork"
    private let claude = BenchDocument.Agent(
        command: "claude", session: "4b1c9e0f-2a3d-4c5e-8f60-718293a4b5c6", cwd: "/tmp/work")

    override func setUpWithError() throws {
        let fm = FileManager.default
        artifacts = fm.temporaryDirectory.appendingPathComponent("helm-ask-fork-\(UUID())")
        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        canvas = artifacts.appendingPathComponent("report.md")
        try "# Report\n\nWhy this exists\n".write(to: canvas, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: artifacts)
    }

    /// A bench with one terminal whose agent record is `author`, the canvas that terminal's agent
    /// opened, and the canvas's model. Mail goes nowhere; `spawn` is answered as benchd would.
    private func openedCanvas(
        by author: BenchDocument.Agent?
    ) throws -> (CanvasModel, FakeBenchd) {
        let terminal = BenchDocument.Pane(id: UUID(), surface: .terminal(agent: author))
        let rig = try toyRig(
            workspace, document: .only(workspace, ToyBench.bench([terminal]))
        ) { terminals, client in
            WorkbenchModel(
                terminals: terminals,
                notes: CanvasNoteCourier(
                    mail: BenchMailbox(who: { _ in nil }, send: { _, _, _, _ in })),
                client: client)
        }
        let toy = rig.server.answer
        rig.server.answer = { request in
            guard request["verb"] as? String == "spawn" else { return toy(request) }
            return [
                "id": request["id"] ?? "", "status": "ok",
                "data": ["handle": "s7", "pane": UUID().uuidString.lowercased()],
            ]
        }
        let pane = try XCTUnwrap(
            rig.model.send(
                .paneOpen(workspace: workspace, surface: .canvas(path: canvas.path)),
                by: .agent(pane: terminal.id.uuidString.lowercased())))
        bench = rig.model
        let model = rig.model.canvas(for: try XCTUnwrap(rig.model.bench?.pane(pane)))
        model.copyToClipboard = { [weak self] text in self?.copied.append(text) }
        return (model, rig.server)
    }

    /// The operator highlights "Why this exists" through the shipped script and asks.
    private func ask(_ question: String, on model: CanvasModel) throws {
        let page = try CanvasScriptRuntime()
        page.setTool(.text)
        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)
        model.pageDidReport(try CanvasPageSelection.decode(try XCTUnwrap(page.lastPosted)).get())
        model.askFork(question: question)
    }

    private func spawns(_ server: FakeBenchd) -> [[String: Any]] {
        server.requests.filter { $0["verb"] as? String == "spawn" }
    }

    func testAskingAForkSpawnsTheAuthorsConversationReadOnlyWithTheMarkAndTheQuestion()
        throws
    {
        let (model, server) = try openedCanvas(by: claude)
        XCTAssertEqual(model.forkRoute(), .fork(claude))

        try ask("why does this exist at all?", on: model)

        let sent = spawns(server)
        XCTAssertEqual(sent.count, 1)
        let args = try XCTUnwrap(sent.first?["args"] as? [String: Any])
        XCTAssertEqual(args["agent"] as? String, "claude")
        XCTAssertEqual(args["fork"] as? String, claude.session)
        XCTAssertEqual(args["cwd"] as? String, claude.cwd)
        XCTAssertEqual((sent.first?["by"] as? [String: Any])?["kind"] as? String, "helm")
        let prompt = try XCTUnwrap(args["prompt"] as? String)
        XCTAssertTrue(prompt.contains("File: \(canvas.path)"), prompt)
        XCTAssertTrue(prompt.contains("Line: 3"), prompt)
        XCTAssertTrue(prompt.contains("```text\nWhy this exists\n```"), prompt)
        XCTAssertTrue(prompt.contains("why does this exist at all?"), prompt)

        XCTAssertEqual(
            model.notesNotice,
            "Written to report.notes.md and asked a fork of the author, in pane s7")
        XCTAssertEqual(copied, [], "the fork has the question; the clipboard is left alone")
    }

    /// The refusals: a pi author, and a canvas whose opener had no conversation recorded. The
    /// action says why and nothing reaches benchd.
    func testACanvasWithNoClaudeAuthorSaysWhyAndSpawnsNothing() throws {
        let pi = BenchDocument.Agent(command: "pi", session: "p-1", cwd: "/tmp/work")
        for (author, reason) in [(pi, "Opened by pi"), (nil, "no recorded conversation")] {
            let (model, server) = try openedCanvas(by: author)
            guard case let .unavailable(why) = model.forkRoute() else {
                return XCTFail("\(String(describing: author)) cannot be forked")
            }
            XCTAssertTrue(why.contains(reason), why)
            try ask("why?", on: model)
            XCTAssertEqual(spawns(server).count, 0)
            XCTAssertEqual(model.notesNotice, "Written to report.notes.md and copied — \(why)")
        }
    }
}
