import HelmWire
import XCTest

@testable import Helm

/// The send half: what a mark hands benchd, and what happens when benchd cannot take it.
///
/// helm keeps no mailroom (#358), so the message format, its file mode and the retired-box rule
/// are benchd's and tested there. What is left here is what helm decides: who it is sent to,
/// what it says, and that a send which fails is never reported as sent.
@MainActor
final class CanvasNoteCourierTests: XCTestCase {
    private let handle = Handle(validating: "sild-611a")!
    private let canvas = URL(fileURLWithPath: "/work/artifacts/plan.md")

    /// **Decoded through `CanvasAnnotation.decode`, not assembled beside it** (#326) — see
    /// `CanvasAnnotationFixture`. A throwing method because the gate can refuse.
    private func annotation(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> CanvasAnnotation {
        try annotation(
            selecting: "The bridge payload", id: "bridge",
            comment: "this shouldn't talk to that", file: file, line: line)
    }

    /// Every send the courier makes, in order.
    private final class Sends: @unchecked Sendable {
        var calls: [(to: Handle, from: String, subject: String, body: String)] = []
    }

    private func mailbox(
        recording sends: Sends, refusing reason: String? = nil
    ) -> BenchMailbox {
        BenchMailbox(
            who: { _ in nil },
            send: { to, from, subject, body in
                if let reason { throw BenchMailbox.Refused(description: reason) }
                sends.calls.append((to, from, subject, body))
            })
    }

    // MARK: - The message

    func testASentNoteGoesToThePanesAgentFromTheOperator() throws {
        let sends = Sends()
        let courier = CanvasNoteCourier(mail: mailbox(recording: sends))
        let annotation = try annotation()

        let delivery = courier.send(annotation, on: canvas, along: .mailbox(handle))

        XCTAssertEqual(delivery, .sent(handle))
        XCTAssertEqual(sends.calls.count, 1, "one mark is one message")
        let call = try XCTUnwrap(sends.calls.first)
        XCTAssertEqual(call.to, handle)
        XCTAssertEqual(call.from, "operator")
        XCTAssertEqual(call.subject, CanvasNoteCourier.subject(for: canvas))
        XCTAssertEqual(call.body, CanvasNoteCourier.body(annotation, on: canvas))
    }

    /// The anchor is the acceptance criterion — an agent handed *"this shouldn't talk to that"*
    /// with no `#bridge` cannot act on it. It is `CanvasNotes.clipboardEntry` verbatim so the
    /// paste and the mail cannot drift into two formats, plus one line saying there is nowhere
    /// to reply.
    func testTheBodyIsTheClipboardEntryPlusWhereToAnswer() throws {
        let annotation = try annotation()
        let body = CanvasNoteCourier.body(annotation, on: canvas)

        XCTAssertTrue(body.hasPrefix(CanvasNotes.clipboardEntry(annotation, for: canvas)))
        XCTAssertTrue(body.contains("`#bridge`"))
        XCTAssertTrue(body.contains("The bridge payload"))
        XCTAssertTrue(body.contains("/work/artifacts/plan.md"))
        XCTAssertTrue(
            body.contains("marked by the operator"),
            "the recipient is told these are the human's words, not a peer agent's")
        XCTAssertTrue(
            body.contains("no mailbox at \"operator\""),
            "…and that replying to the sender address goes nowhere")
    }

    /// The subject is all a recipient's notice shows of a message
    /// (benchd's pointer line), so it has to name the artifact on one line.
    func testTheSubjectNamesTheCanvasOnOneLine() {
        let subject = CanvasNoteCourier.subject(for: canvas)

        XCTAssertEqual(subject, "canvas note on plan.md")
        XCTAssertFalse(subject.contains("\n"))
    }

    // MARK: - What must not happen

    func testAnUnroutedNoteSendsNothingAtAll() throws {
        let sends = Sends()
        let courier = CanvasNoteCourier(mail: mailbox(recording: sends))
        let annotation = try annotation()

        for fallback in [CanvasNoteRoute.Fallback.noOrigin, .originGone] {
            XCTAssertEqual(
                courier.send(annotation, on: canvas, along: .clipboard(fallback)),
                .notSent(fallback))
        }
        XCTAssertEqual(sends.calls.count, 0, "not a message to a handle helm made up")
    }

    /// **A send benchd refuses is `.failed`, carrying benchd's reason.** The operator believes a
    /// `.sent` note reached the agent, so a refusal read as success is the failure this path
    /// exists to remove — and the reason is what tells them whether the agent is gone or benchd is.
    func testARefusedSendIsAFailureThatSaysWhy() throws {
        let sends = Sends()
        let courier = CanvasNoteCourier(
            mail: mailbox(recording: sends, refusing: "no mailbox at sild-611a"))

        let delivery = try courier.send(annotation(), on: canvas, along: .mailbox(handle))

        guard case let .failed(named, why) = delivery else {
            return XCTFail("expected a failure, got \(delivery)")
        }
        XCTAssertEqual(named, handle)
        XCTAssertTrue(why.contains("no mailbox at sild-611a"), why)
    }
}
