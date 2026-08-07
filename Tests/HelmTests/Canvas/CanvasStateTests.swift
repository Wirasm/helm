import Combine
import XCTest

@testable import Helm

/// **The latch, over the store** (#110) — what a page may say, what lands on disk, and what
/// helm pointedly does not do about it.
///
/// #110's acceptance asks to be covered *"by a test over the store, not by playing a game"*, and
/// that is what this is: no window, no WebKit, no artifact rendering itself. `CanvasStateLiveTests`
/// beside it is the join — a real page on a real origin actually reaching the handler — and the
/// two are split for the reason #216 made expensive, so neither is asked to stand alone.
@MainActor
final class CanvasStateTests: XCTestCase {
    private var directory: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-canvas-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("motions.html")
        try "<!doctype html><html><body>game</body></html>"
            .write(to: artifact, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func body(_ object: [String: Any]) throws -> CanvasStateBody {
        try CanvasStateBody(object)
    }

    /// The latch as an agent reads it: parsed JSON, or nil when there is no file at all.
    private func latchOnDisk() throws -> [String: Any]? {
        let url = CanvasStateLatch.sidecarURL(for: artifact)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func report(_ object: [String: Any]) -> Any {
        ["kind": CanvasPageState.Kind.state.rawValue, "state": object]
    }

    // MARK: - What the agent reads, and from where

    /// **Latest-wins overwrite, which is the whole design.** `CanvasNotes` appends because it
    /// holds what a human wrote; this replaces because the current score is the answer and every
    /// earlier score is noise an agent has to read past to find it.
    func testTheLatchIsOverwrittenSoTheAgentReadsTheStateAndNotAHistory() throws {
        try CanvasStateLatch.write(
            body(["score": 1, "lesson": "dw"]), for: artifact, at: Date(timeIntervalSince1970: 0))
        try CanvasStateLatch.write(
            body(["score": 42, "lesson": "ci("]), for: artifact,
            at: Date(timeIntervalSince1970: 60))

        let latch = try XCTUnwrap(try latchOnDisk())
        let state = try XCTUnwrap(latch["state"] as? [String: Any])
        XCTAssertEqual(state["score"] as? Int, 42)
        XCTAssertEqual(
            state["lesson"] as? String, "ci(",
            "the second report replaced the first — an append log of machine state is noise, and "
                + "an agent reading it would have to work out which entry is current")
        XCTAssertEqual(
            latch["writtenAt"] as? String, "1970-01-01T00:01:00Z",
            "and the timestamp is the LAST write's, or staleness cannot be checked at all")
    }

    /// **It is read outside the process, so it says what it is** — `AGENTS.md`'s rule, and
    /// `BenchSnapshot`'s shape. The reader is an agent with `cat` and `jq`, not Swift, so there is
    /// no far-side type to compile against and this envelope is the only thing that can make a
    /// version skew loud rather than silently misread.
    func testTheFileSaysWhatItIsWhenItWasWrittenAndWhichArtifactItIsAbout() throws {
        try CanvasStateLatch.write(
            body(["score": 3]), for: artifact, at: Date(timeIntervalSince1970: 1_754_000_000))

        let latch = try XCTUnwrap(try latchOnDisk())
        XCTAssertEqual(latch["format"] as? String, "helm.canvas-state")
        XCTAssertEqual(latch["version"] as? Int, 1)
        XCTAssertEqual(latch["artifact"] as? String, "motions.html")
        XCTAssertEqual(
            latch["writtenAt"] as? String, "2025-07-31T22:13:20Z",
            "ISO 8601, the same spelling `BenchSnapshot` writes — a reader should not need a "
                + "second date parser for helm's second reportable file")
        XCTAssertFalse(
            (latch["artifact"] as? String ?? "").contains("/"),
            "the file name, never the path: the latch already sits in the artifact's directory, "
                + "so a path buys a reader nothing and puts the operator's home directory into a "
                + "file an agent may quote back")
    }

    /// helm does not know what a score is, and must not flatten one on the way through.
    func testThePagesOwnJsonCrossesVerbatimWhateverShapeItIs() throws {
        try CanvasStateLatch.write(
            body([
                "score": 12,
                "lesson": ["index": 3, "title": "word motions"],
                "history": ["w", "b", "e"],
                "accuracy": 0.75,
                "finished": false,
            ]),
            for: artifact, at: Date())

        let state = try XCTUnwrap(try XCTUnwrap(latchOnDisk())["state"] as? [String: Any])
        XCTAssertEqual((state["lesson"] as? [String: Any])?["title"] as? String, "word motions")
        XCTAssertEqual(state["history"] as? [String], ["w", "b", "e"])
        XCTAssertEqual(state["accuracy"] as? Double, 0.75)
        XCTAssertEqual(state["finished"] as? Bool, false)
    }

    /// **The operator's notes and the page's state are two files, and neither can reach the
    /// other.** #110's acceptance in one assertion: a page cannot append to what the human wrote,
    /// and helm's own append-never-rewrite rule for annotations is not weakened by anything here.
    func testTheLatchAndTheOperatorsNotesAreSeparateFilesThatDoNotTouch() throws {
        XCTAssertNotEqual(
            CanvasStateLatch.sidecarURL(for: artifact), CanvasNotes.sidecarURL(for: artifact),
            "one file for both would let a page overwrite the operator's comments")

        let annotation = CanvasAnnotation(
            mark: .selection(.quote("game")), comment: "make the timer longer")
        try CanvasNotes.append(annotation, for: artifact, at: Date(timeIntervalSince1970: 0))
        try CanvasStateLatch.write(body(["score": 9]), for: artifact, at: Date())
        try CanvasNotes.append(annotation, for: artifact, at: Date(timeIntervalSince1970: 60))

        let notes = try XCTUnwrap(CanvasNotes.markdown(in: CanvasNotes.sidecarURL(for: artifact)))
        XCTAssertEqual(
            CanvasNotes.headings(in: notes).count, 2,
            "the notes are still append-only and still whole — a state write between them must "
                + "not have replaced, truncated or reordered anything")
        XCTAssertFalse(notes.contains("score"), "and machine state is not in the operator's notes")
        let latch = try XCTUnwrap(try latchOnDisk())
        XCTAssertEqual((latch["state"] as? [String: Any])?["score"] as? Int, 9)
    }

    // MARK: - What a page may say

    /// The one name an artifact author has to know. If it drifts, every page that reports state
    /// silently reports into nothing — the failure with no symptom.
    func testTheHandlerIsTheNameTheContractDocumentsAndIsNotTheAnnotationBridges() {
        XCTAssertEqual(CanvasPageState.handlerName, "helmCanvasState")
        XCTAssertNotEqual(
            CanvasPageState.handlerName, CanvasBridgePolicy.handlerName,
            "sharing a name would put page speech and operator intent on one receiver, which is "
                + "the one thing #164 exists to prevent")
    }

    /// **Every kind the channel declares is one it can decode.** `CaseIterable` makes this a gate
    /// over the whole enum rather than over the sample somebody remembered to write, so a second
    /// kind added without a decode arm fails here instead of shipping.
    func testEveryKindTheChannelDeclaresIsOneItCanActuallyDecode() throws {
        for kind in CanvasPageState.Kind.allCases {
            let message: Any = ["kind": kind.rawValue, "state": ["ok": true]]
            switch CanvasPageState.decode(message) {
            case .success: continue
            case let .failure(refusal):
                XCTFail("`\(kind.rawValue)` is declared but refused: \(refusal.reason)")
            }
        }
    }

    /// **An unknown kind is refused BY NAME.** That is the whole point of a discriminator, and
    /// #216 is the bill for the version that inferred the shape instead: a decoder that dropped
    /// every geometry mark for months with every test on both sides green.
    func testAnUnknownKindIsRefusedAndTheRefusalSaysWhichOne() {
        let refusal = self.refusal(from: ["kind": "canvas.telemetry", "state": ["x": 1]])
        XCTAssertEqual(refusal, .unknownKind("canvas.telemetry"))
        XCTAssertTrue(
            refusal?.reason.contains("canvas.telemetry") == true,
            "a drop nobody can name is a drop nobody can fix")
    }

    func testAMessageWithNoKindAtAllIsRefused() {
        XCTAssertEqual(refusal(from: ["state": ["score": 1]]), .noKind)
        XCTAssertEqual(refusal(from: "canvas.state"), .notAnObject)
    }

    func testAKindWithNoStateBesideItIsRefused() {
        XCTAssertEqual(refusal(from: ["kind": "canvas.state"]), .noState)
    }

    /// **A JSON object, never an array or a scalar.** An agent reading the latch should be able
    /// to say `state.score` without first asking what shape it got.
    func testAStateThatIsNotAnObjectIsRefusedRatherThanLatchedAsOne() {
        for notAnObject in [[1, 2, 3] as Any, 42 as Any, "playing" as Any, true as Any] {
            XCTAssertEqual(
                refusal(from: ["kind": "canvas.state", "state": notAnObject]),
                .invalidState(.notAnObject),
                "\(notAnObject) is not a latch an agent can address into")
        }
    }

    /// **The limit is about the reader, not the disk.** Every byte of the latch lands in the
    /// agent's context window on its next turn.
    func testAStateTooLargeToLandInAnAgentsContextIsRefusedAndSaysHowBig() throws {
        let huge = ["log": String(repeating: "x", count: CanvasStateBody.maxBytes)]
        guard
            case let .invalidState(invalid)? = refusal(from: [
                "kind": "canvas.state", "state": huge,
            ])
        else { return XCTFail("a state over the limit must be refused") }
        guard case let .tooLarge(bytes) = invalid else {
            return XCTFail("and refused as too large, not as malformed: \(invalid)")
        }
        XCTAssertGreaterThan(bytes, CanvasStateBody.maxBytes)
        XCTAssertTrue(invalid.reason.contains("\(bytes)"), "the page's author needs the number")

        // The control: one byte under the limit is fine, so this is a limit and not a refusal to
        // carry anything substantial.
        let large = ["log": String(repeating: "x", count: CanvasStateBody.maxBytes - 100)]
        XCTAssertNil(refusal(from: ["kind": "canvas.state", "state": large]))
    }

    /// Two reports of the same state are the same state, whatever order the page's own
    /// `JSON.stringify` emitted the keys in — which is what makes the dedupe below a statement
    /// about the state rather than about the page's serializer.
    func testTwoReportsOfOneStateAreEqualWhateverOrderThePageSerializedThem() throws {
        let one = try CanvasStateBody(["score": 4, "lesson": "dw", "at": 9])
        let other = try CanvasStateBody(["at": 9, "lesson": "dw", "score": 4])
        XCTAssertEqual(one, other)
        XCTAssertNotEqual(one, try CanvasStateBody(["score": 5, "lesson": "dw", "at": 9]))
    }

    private func refusal(from message: Any) -> CanvasPageState.Refusal? {
        switch CanvasPageState.decode(message) {
        case .success: nil
        case let .failure(refusal): refusal
        }
    }

    // MARK: - What the pane does about it, and what it pointedly does not

    /// **The acceptance, at the model.** A report lands beside the artifact and moves nothing
    /// else: no notice, no selection, nothing in the operator's notes, and — the assertion that
    /// makes "no interrupt" checkable rather than argued — **not even a redraw of the pane the
    /// operator is playing in**.
    func testAReportLandsInTheLatchAndDisturbsNothingElseAtAll() throws {
        let model = CanvasModel()
        model.open(artifact)

        var redraws = 0
        let subscription = model.objectWillChange.sink { _ in redraws += 1 }
        defer { subscription.cancel() }

        model.pageDidReportState(try state(["score": 7, "lesson": "dw"]))

        let latch = try XCTUnwrap(try latchOnDisk())
        XCTAssertEqual((latch["state"] as? [String: Any])?["score"] as? Int, 7)
        XCTAssertEqual(
            redraws, 0,
            "the operator is mid-play in the page that sent this; a redraw around them is the "
                + "smallest version of the interruption the latch exists to avoid")
        XCTAssertNil(model.updateNotice)
        XCTAssertNil(model.notesNotice)
        XCTAssertNil(model.notesFailure)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.notesText)
        XCTAssertTrue(model.notes.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: CanvasNotes.sidecarURL(for: artifact).path),
            "machine state must never create, let alone touch, the operator's notes")
    }

    /// **An unchanged report costs no write**, which is what makes `writtenAt` mean *"the page
    /// last did something different"* rather than *"the page last spoke"* — the staleness signal
    /// SWE-Touch measured agents losing points for not having.
    ///
    /// Deleting the file between the two reports is the instrument: the latch coming back would
    /// **be** the second write, with no clock to inject and no timestamp resolution to depend on.
    func testRepeatingTheSameStateDoesNotRewriteTheLatch() throws {
        let model = CanvasModel()
        model.open(artifact)
        let unchanged = try state(["score": 7])

        model.pageDidReportState(unchanged)
        XCTAssertNotNil(try latchOnDisk(), "the first report is written")

        try FileManager.default.removeItem(at: CanvasStateLatch.sidecarURL(for: artifact))
        model.pageDidReportState(unchanged)

        XCTAssertNil(
            try latchOnDisk(),
            "a page re-reporting the state it already reported must not rewrite the file — one "
                + "on a requestAnimationFrame loop would otherwise write sixty times a second to "
                + "say nothing, and `writtenAt` would stop meaning anything")
    }

    /// **The control for the dedupe, and it must fail if the dedupe overshoots.** A rule
    /// satisfied by never writing is satisfied by the feature not working.
    func testAStateThatActuallyChangedIsWrittenEveryTime() throws {
        let model = CanvasModel()
        model.open(artifact)

        model.pageDidReportState(try state(["score": 7]))
        try FileManager.default.removeItem(at: CanvasStateLatch.sidecarURL(for: artifact))
        model.pageDidReportState(try state(["score": 8]))

        let latch = try XCTUnwrap(try latchOnDisk())
        XCTAssertEqual((latch["state"] as? [String: Any])?["score"] as? Int, 8)
    }

    /// A pane that moves to another artifact must not dedupe the new page's first report against
    /// the old page's state — which would be a latch that silently never appeared.
    func testOpeningAnotherArtifactForgetsWhatThisPaneHadAlreadyLatched() throws {
        let model = CanvasModel()
        model.open(artifact)
        let same = try state(["score": 7])
        model.pageDidReportState(same)

        let second = directory.appendingPathComponent("other.html")
        try "<!doctype html><html><body>other</body></html>"
            .write(to: second, atomically: true, encoding: .utf8)
        model.open(second)
        model.pageDidReportState(same)

        let latch = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try Data(contentsOf: CanvasStateLatch.sidecarURL(for: second)))
                as? [String: Any])
        XCTAssertEqual(latch["artifact"] as? String, "other.html")
        XCTAssertEqual((latch["state"] as? [String: Any])?["score"] as? Int, 7)
    }

    /// A URL canvas has no file to write beside, and a report from one must go nowhere rather
    /// than somewhere invented.
    func testAReportFromACanvasWithNoFileIsDropped() throws {
        let model = CanvasModel()
        model.openURL(URL(string: "https://example.com/dashboard")!)
        model.pageDidReportState(try state(["score": 7]))
        XCTAssertNil(try latchOnDisk())
    }

    private func state(_ object: [String: Any]) throws -> CanvasPageState {
        switch CanvasPageState.decode(report(object)) {
        case let .success(state): return state
        case let .failure(refusal): throw refusal
        }
    }
}
