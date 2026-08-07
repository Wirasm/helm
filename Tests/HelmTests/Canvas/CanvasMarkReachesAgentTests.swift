import HelmWire
import XCTest

@testable import Helm

/// **The join, driven end to end with a real message.** A gesture on the page, the shipped
/// `canvas-annotation.js` running in JavaScriptCore, the message it actually posts, the gate that
/// admits it, the model, the decoder, the sidecar, and a file appearing in a real mailbox on disk.
///
/// **Every step here is one somebody already tested in isolation, and that is the point.** #216
/// shipped for months with both sides green: `CanvasPageSelection.init?` admitted a body only if
/// it carried a top-level non-empty `text`, so every geometry mark was dropped before it reached
/// the decoder that understands it — and the decoder's own suite passed, because it was handed
/// dictionaries by hand. Nothing crossed. So the messages below are never written out as literals:
/// they come out of the script, whatever the script says they are.
///
/// `CanvasNoteRouteTests` holds the routing decision on its own, and `CanvasNoteCourierTests` the
/// mailbox write on its own. This is the one that fails when they stop meeting.
@MainActor
final class CanvasMarkReachesAgentTests: XCTestCase {
    private var mailRoot: URL!
    private var artifacts: URL!
    private var canvas: URL!

    private let handle = Handle(validating: "sild-611a")!
    private let agentPid: pid_t = 40501

    /// What `annotate` put on the clipboard, for the suite's own clipboard rather than the
    /// operator's — `CanvasModel.copyToClipboard`'s header has why that distinction is not
    /// pedantry. Before #303 this suite wrote to `NSPasteboard.general` on every run.
    private var copied: [String] = []

    override func setUpWithError() throws {
        let fm = FileManager.default
        mailRoot = fm.temporaryDirectory.appendingPathComponent("helm-mark-mail-\(UUID())")
        artifacts = fm.temporaryDirectory.appendingPathComponent("helm-mark-canvas-\(UUID())")
        try fm.createDirectory(
            at: mailRoot.appendingPathComponent(handle.value), withIntermediateDirectories: true)
        try """
        {"handle":"\(handle.value)","runtime":"claude","pid":\(agentPid),
         "sessionId":"e6f1c2d8-0000-4000-8000-0000000611a4","cwd":"/work",
         "claimedAt":1785831967319}
        """
        .write(
            to: mailRoot.appendingPathComponent("\(handle.value)/owner.json"),
            atomically: true, encoding: .utf8)

        try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
        canvas = artifacts.appendingPathComponent("plan.md")
        try "# The Plan\n\nWhy this exists\n".write(to: canvas, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: mailRoot)
        try? FileManager.default.removeItem(at: artifacts)
    }

    // MARK: - Driving the whole path

    /// A canvas wired the way `WorkbenchModel` wires one, minus the bench: the courier is real,
    /// the mailbox is real, and only the route is stated rather than resolved from a live pty.
    private func openCanvas(routedTo route: CanvasNoteRoute) -> CanvasModel {
        let model = CanvasModel(source: .file(canvas))
        let courier = CanvasNoteCourier(mailboxRoot: mailRoot)
        model.onAnnotation = { annotation, canvas in
            courier.send(annotation, on: canvas, along: route)
        }
        model.copyToClipboard = { [weak self] text in self?.copied.append(text) }
        return model
    }

    /// A text highlight, which the script posts on **mouseup** rather than on the selection
    /// itself — a highlight the operator is still dragging is not a mark.
    private func highlight(_ page: CanvasScriptRuntime) {
        page.select(id: "intro", text: "Why this exists")
        page.mouse("mouseup", 100, 110)
    }

    /// The gesture, the script, and the two hops a `WKScriptMessage` takes in
    /// `CanvasMessageHandler.userContentController` — `CanvasPageSelection(message.body)` and then
    /// `onAnnotation`, which is `CanvasModel.pageDidReport`.
    private func mark(
        _ gesture: (CanvasScriptRuntime) -> Void, saying comment: String,
        on model: CanvasModel
    ) throws {
        let page = try CanvasScriptRuntime()
        gesture(page)
        let body = try XCTUnwrap(page.lastPosted, "the gesture posted nothing to comment on")
        let report = try CanvasPageSelection.decode(body).get()
        model.pageDidReport(report)
        model.annotate(comment: comment)
        XCTAssertTrue(page.drainExceptions().isEmpty)
    }

    /// Between the iterations of a loop that marks more than once — the owner stays, the mail
    /// goes, so `delivered()` keeps meaning "the message this iteration sent".
    private func emptyTheMailbox() throws {
        let box = mailRoot.appendingPathComponent(handle.value)
        for name in try FileManager.default.contentsOfDirectory(atPath: box.path)
        where name != "owner.json" {
            try FileManager.default.removeItem(at: box.appendingPathComponent(name))
        }
    }

    private func delivered() throws -> [String: Any] {
        let box = mailRoot.appendingPathComponent(handle.value)
        let names = try FileManager.default.contentsOfDirectory(atPath: box.path)
            // The two rules both mailbox readers apply — `hooks/helm-mail.mjs:118`.
            .filter { $0.hasSuffix(".json") && $0 != "owner.json" && !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1, "exactly one message, named \(names)")
        let name = try XCTUnwrap(names.first)
        let data = try Data(contentsOf: box.appendingPathComponent(name))
        let message = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            "\(try XCTUnwrap(message["id"] as? String)).json", name,
            "the filename is the id, which is how a reader names the file back")
        return message
    }

    // MARK: - A selection

    /// The plain case, and the one that worked before #205 as far as the clipboard.
    func testASelectionMarkedOnAPushedCanvasReachesThatAgentsMailbox() throws {
        let model = openCanvas(routedTo: .mailbox(handle))

        try mark(
            highlight, saying: "this shouldn't talk to that", on: model)

        let message = try delivered()
        XCTAssertEqual(message["to"] as? String, handle.value)
        XCTAssertEqual(message["from"] as? String, CanvasNoteCourier.sender)
        XCTAssertEqual(message["subject"] as? String, "canvas note on plan.md")

        let body = try XCTUnwrap(message["body"] as? String)
        XCTAssertTrue(
            body.contains("`#intro`"),
            "#205: an agent that receives the prose with no anchor cannot act on it — \(body)")
        XCTAssertTrue(body.contains("Why this exists"), "…nor verify the anchor resolved right")
        XCTAssertTrue(body.contains("this shouldn't talk to that"))
        XCTAssertTrue(body.contains(canvas.path), "and it has to say which canvas")
    }

    // MARK: - The geometry marks

    /// **The one #216 would have caught, and the reason this file drives the script rather than
    /// building a body.** An enclosure carries `targets`, never a top-level `text`, so the gate at
    /// `CanvasPageSelection.init?` is the first thing it meets on the way to a mailbox — and that
    /// gate is exactly where every geometry mark was silently dropped for months.
    func testACircleDrawnRoundAnElementReachesTheMailboxCarryingWhatItCovered() throws {
        let model = openCanvas(routedTo: .mailbox(handle))

        try mark(
            { page in
                page.setTool(.freehand)
                page.loop(around: (x: 10, y: 1390, width: 320, height: 50))
            }, saying: "circle this one", on: model)

        let body = try XCTUnwrap(try delivered()["body"] as? String)
        XCTAssertTrue(
            body.contains("circled"), "the gesture is the verb an agent greps for — \(body)")
        XCTAssertTrue(body.contains("`#item-a`"), "and it names what the loop actually covered")
        XCTAssertTrue(body.contains("circle this one"))
    }

    /// The other two geometry marks, for the same reason: `relation` carries `from`/`to` and
    /// `point` carries neither `targets` nor a plain selection, so each crosses the gate on its
    /// own discriminator.
    func testAnArrowAndAPointBothReachTheMailboxToo() throws {
        for (tool, gesture, expected) in [
            (
                CanvasMarkTool.arrow,
                { (page: CanvasScriptRuntime) in
                    page.drag(from: (x: 100, y: 100), to: (x: 100, y: 1410))
                }, "arrow"
            ),
            (
                CanvasMarkTool.point,
                { (page: CanvasScriptRuntime) in page.tap(at: (x: 100, y: 110)) },
                "pointed at"
            ),
        ] {
            try emptyTheMailbox()

            let model = openCanvas(routedTo: .mailbox(handle))
            try mark(
                { page in
                    page.setTool(tool)
                    gesture(page)
                }, saying: "look here", on: model)

            let body = try XCTUnwrap(try delivered()["body"] as? String)
            XCTAssertTrue(
                body.contains(expected),
                "a \(tool.token) mark has to survive the whole path — \(body)")
        }
    }

    // MARK: - The sidecar, and the fallback

    /// **The sidecar is the memory; mail is delivery, not storage** (#205's acceptance). It is
    /// written whichever way the note is routed, and it is written *first*, so a mailbox that has
    /// gone away never costs the operator the note itself.
    func testTheSidecarIsWrittenWhetherOrNotTheNoteIsRouted() throws {
        for route in [CanvasNoteRoute.mailbox(handle), .clipboard(.noOrigin)] {
            let model = openCanvas(routedTo: route)
            try mark(
                highlight, saying: "one note, route \(route)", on: model)

            let sidecar = try String(
                contentsOf: CanvasNotes.sidecarURL(for: canvas), encoding: .utf8)
            XCTAssertTrue(sidecar.contains("one note, route \(route)"))
            XCTAssertTrue(sidecar.contains("`#intro`"))
            try FileManager.default.removeItem(at: CanvasNotes.sidecarURL(for: canvas))
        }
    }

    /// A canvas with no origin sends nothing at all — not an empty file, not a message to a
    /// handle helm invented — **and says so**, because a silent no-op here is the worst outcome:
    /// the operator believes the note was sent.
    func testACanvasWithNoOriginSendsNothingAndTheNoticeSaysSo() throws {
        let model = openCanvas(routedTo: .clipboard(.noOrigin))

        try mark(
            highlight, saying: "nobody to tell", on: model)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: mailRoot.appendingPathComponent(handle.value).path),
            ["owner.json"], "an unrouted note must not write into a mailbox at all")
        XCTAssertEqual(
            model.notesNotice,
            "Written to plan.notes.md and copied — no agent pushed this canvas, so paste it to one")
    }

    /// And the routed case says the other thing — the handle it reached.
    func testARoutedNoteSaysWhichAgentItReached() throws {
        let model = openCanvas(routedTo: .mailbox(handle))

        try mark(
            highlight, saying: "over here", on: model)

        XCTAssertEqual(
            model.notesNotice, "Written to plan.notes.md and sent to sild-611a")
    }

    // MARK: - The clipboard (#303)

    /// **The seam, driven through a real gesture.** `CanvasNoteRouteTests` holds the rule —
    /// `copiesToClipboard` is false for `sent` and true for the other three — and this is what says
    /// `annotate` spends it. #216 is the argument for testing the join at all: a rule and a pipeline
    /// were each green for months while nothing crossed between them.
    func testANoteThatReachedTheAgentIsNotAlsoTakenToTheClipboard() throws {
        let model = openCanvas(routedTo: .mailbox(handle))

        try mark(highlight, saying: "the agent has this", on: model)

        XCTAssertFalse(
            try XCTUnwrap(try delivered()["body"] as? String).isEmpty,
            "the premise: this note really was delivered")
        XCTAssertEqual(
            copied, [], "a delivered note must not also replace what the operator had copied")
    }

    /// **Control**, and the one that keeps the test above from being satisfied by never copying at
    /// all. With nobody to send to, the clipboard *is* the return path and the note has to land on
    /// it, carrying the anchor — `CanvasClipboardTests` holds what that text is made of.
    func testANoteWithNowhereToGoIsStillPutOnTheClipboard() throws {
        let model = openCanvas(routedTo: .clipboard(.noOrigin))

        try mark(highlight, saying: "nowhere to send this", on: model)

        XCTAssertEqual(copied.count, 1, "the unrouted note is the operator's only copy")
        let text = try XCTUnwrap(copied.first)
        XCTAssertTrue(text.contains("nowhere to send this"))
        XCTAssertTrue(text.contains("`#intro`"), "and it carries the anchor, not just the prose")
    }
}
