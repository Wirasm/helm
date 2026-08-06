import HelmWire
import XCTest

@testable import Helm

/// The write half: what actually lands in a mailbox, and what happens when it cannot.
///
/// helm has only ever *read* the mailbox, so this is the first Swift writer of a format whose two
/// readers are JavaScript in other processes (`hooks/helm-mail.mjs`, `pi/extensions/helm-mail/`).
/// Nothing in `swift test` can run either of them — so what is asserted here is every rule those
/// readers apply, taken from their source and named against it.
@MainActor
final class CanvasNoteCourierTests: XCTestCase {
    private var root: URL!
    private let handle = Handle(validating: "sild-611a")!
    private let canvas = URL(fileURLWithPath: "/work/artifacts/plan.md")

    private var annotation: CanvasAnnotation {
        CanvasAnnotation(
            anchor: .element(id: "bridge", text: "The bridge payload"),
            comment: "this shouldn't talk to that")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-courier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(handle.value), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private var box: URL { root.appendingPathComponent(handle.value) }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: box.path).sorted()
    }

    // MARK: - The message

    func testASentNoteLandsAsOneMessageNamedByItsOwnID() throws {
        let courier = CanvasNoteCourier(mailboxRoot: root, now: { Date(timeIntervalSince1970: 42) })

        let delivery = courier.send(annotation, on: canvas, along: .mailbox(handle))

        XCTAssertEqual(delivery, .sent(handle))
        let written = try names()
        XCTAssertEqual(written.count, 1, "\(written)")
        let name = try XCTUnwrap(written.first)
        XCTAssertTrue(
            name.hasSuffix(".json") && !name.hasPrefix("."),
            "both readers filter on exactly these two rules (hooks/helm-mail.mjs:118) — \(name)")
        XCTAssertTrue(name.hasPrefix("42000-"), "the id opens with the epoch millis it was sent at")

        let message = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: box.appendingPathComponent(name))) as? [String: Any])
        XCTAssertEqual(message["id"] as? String, String(name.dropLast(".json".count)))
        XCTAssertEqual(message["sentAt"] as? Int, 42000)
        XCTAssertEqual(message["to"] as? String, handle.value)
        XCTAssertEqual(
            Set((message as [String: Any]).keys),
            ["id", "from", "to", "subject", "body", "sentAt"],
            "the shape both runtimes read, and nothing extra they would ignore")
    }

    /// **`sentAt` is derived from `id`, so they cannot disagree.** The documented way to send is
    /// `'sentAt': int(id.split('-')[0])` — one number in two fields, with nothing to notice when a
    /// caller passes a different clock to each.
    func testTheTimestampAndTheIdAreTheSameNumber() {
        let message = MailMessage(
            from: "operator", to: handle, subject: "s", body: "b",
            at: Date(timeIntervalSince1970: 1_786_000_000.5))

        XCTAssertEqual(message.sentAt, 1_786_000_000_500)
        XCTAssertEqual(message.id.split(separator: "-").first.map(String.init), "1786000000500")
    }

    /// The anchor is the acceptance criterion — an agent handed *"this shouldn't talk to that"*
    /// with no `#bridge` cannot act on it. It is `CanvasNotes.clipboardEntry` verbatim so the
    /// paste and the mail cannot drift into two formats, plus one line saying there is nowhere
    /// to reply.
    func testTheBodyIsTheClipboardEntryPlusWhereToAnswer() {
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
    /// (`hooks/helm-mail.mjs`'s `notice`), so it has to name the artifact on one line.
    func testTheSubjectNamesTheCanvasOnOneLine() {
        let subject = CanvasNoteCourier.subject(for: canvas)

        XCTAssertEqual(subject, "canvas note on plan.md")
        XCTAssertFalse(subject.contains("\n"))
    }

    // MARK: - What must not happen

    func testAnUnroutedNoteWritesNothingAtAll() throws {
        let courier = CanvasNoteCourier(mailboxRoot: root)

        for fallback in [CanvasNoteRoute.Fallback.noOrigin, .originGone] {
            XCTAssertEqual(
                courier.send(annotation, on: canvas, along: .clipboard(fallback)),
                .notSent(fallback))
        }
        XCTAssertEqual(try names(), [], "not an empty file, and not a directory helm invented")
    }

    /// **A mailbox helm invented is silence with a receipt.** A directory under the mail root *is*
    /// an address; one with no owner has nobody watching it, and a message put there is never read
    /// and never bounces (`MailboxDirectory.owners(in:)` on retirement says the same thing about
    /// the retired case). So a missing box is refused and the operator is told.
    func testAMailboxThatIsNotThereIsRefusedRatherThanCreated() throws {
        let courier = CanvasNoteCourier(mailboxRoot: root)
        let gone = Handle(validating: "reaped-0000")!

        let delivery = courier.send(annotation, on: canvas, along: .mailbox(gone))

        guard case let .failed(named, why) = delivery else {
            return XCTFail("expected a failure, got \(delivery)")
        }
        XCTAssertEqual(named, gone)
        XCTAssertTrue(why.contains("no mailbox"), why)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(gone.value).path),
            "and the refusal must not leave a directory behind that a sender would then pick")
    }

    /// **A message is `0600`, because both other writers make it so** — `writeAtomic` in
    /// `hooks/helm-mail.mjs:99` and `pi/extensions/helm-mail/index.ts:284`, and `index.ts:484`
    /// sends every message through it. It is a real part of the shared on-disk shape rather than a
    /// detail of the owner record: the body of a canvas note is whatever the operator typed about
    /// their own work, and a third writer that quietly widened it to the umask would leave the
    /// same directory holding files with two different postures depending on who sent them.
    ///
    /// `Data.write(options: .atomic)` does **not** carry a mode — it creates the file with the
    /// process umask — so this has to be asked for, which is why it is asserted rather than
    /// assumed.
    func testAMessageIsWrittenPrivateLikeEveryOtherWritersIs() throws {
        _ = CanvasNoteCourier(mailboxRoot: root).send(
            annotation, on: canvas, along: .mailbox(handle))

        let name = try XCTUnwrap(try names().first { $0.hasSuffix(".json") })
        let attributes = try FileManager.default.attributesOfItem(
            atPath: box.appendingPathComponent(name).path)
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600,
            "both JS writers set mode 0o600 on a message; a third that does not is a posture "
                + "that depends on which agent sent it")
    }

    /// **A retired mailbox is refused, and refused DIFFERENTLY from one that never existed.**
    /// Since #236 a gone agent's directory stays on disk forever with its `read/` archive, so
    /// "does the directory exist" cannot tell live from gone — and a message put in a retired box
    /// is never read and never bounces. `pi/extensions/helm-mail/index.ts:465-473` refuses exactly
    /// this, in exactly these two ways, and its comment says why: *"a sender holding a handle from
    /// an earlier message learns the agent is gone, instead of writing into a live-looking
    /// directory and waiting forever for a reply."* Swift is a sender now and must say the same.
    ///
    /// The route cannot normally hand one over — `MailboxDirectory.owners(in:)` drops retired rows
    /// before `CanvasNoteRoute` ever sees them — but `Mailbox.deliver` is written as the general
    /// way to send, and the next caller will not have that filter in front of it.
    func testARetiredMailboxIsRefusedAndSaysSomethingDifferentFromAMissingOne() throws {
        try """
        {"handle":"\(handle.value)","runtime":"claude","pid":40501,
         "sessionId":"e6f1c2d8-0000-4000-8000-0000000611a4","cwd":"/work",
         "claimedAt":1785831967319,"retiredAt":1786040000000}
        """
        .write(to: box.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        let delivery = CanvasNoteCourier(mailboxRoot: root)
            .send(annotation, on: canvas, along: .mailbox(handle))

        guard case let .failed(named, why) = delivery else {
            return XCTFail("a retired mailbox must refuse, got \(delivery)")
        }
        XCTAssertEqual(named, handle)
        XCTAssertTrue(why.contains("retired"), why)
        XCTAssertNotEqual(
            why, Mailbox.Failure.noSuchMailbox(handle.value).localizedDescription,
            "gone and never-existed are different facts to the operator, and to the next sender")
        XCTAssertEqual(
            try names(), ["owner.json"], "and nothing was written into the archive")
    }

    /// The control for the rule above: an owner record that is **not** retired still receives.
    /// Without it, "refuse a retired mailbox" is satisfied by refusing every mailbox.
    func testALiveOwnerRecordBesideTheMailboxDoesNotStopADelivery() throws {
        try """
        {"handle":"\(handle.value)","runtime":"claude","pid":40501,
         "sessionId":"e6f1c2d8-0000-4000-8000-0000000611a4","cwd":"/work",
         "claimedAt":1785831967319}
        """
        .write(to: box.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            CanvasNoteCourier(mailboxRoot: root)
                .send(annotation, on: canvas, along: .mailbox(handle)),
            .sent(handle))
        XCTAssertEqual(try names().filter { $0 != "owner.json" }.count, 1)
    }

    /// **A mailbox with no `owner.json` at all still receives**, which is pi's behaviour to the
    /// letter (`readJson` yields undefined, the `owner?.retiredAt` check is falsy, the send goes
    /// through). Refusing here instead would be a *stricter* Swift than the sibling implementation
    /// — one rule with two spellings, which is the defect being avoided rather than a safer one.
    func testAMailboxWithNoOwnerRecordIsNotTreatedAsRetired() throws {
        XCTAssertEqual(
            CanvasNoteCourier(mailboxRoot: root)
                .send(annotation, on: canvas, along: .mailbox(handle)),
            .sent(handle))
    }

    /// The staged name is invisible to a reader by both of its rules, and nothing is left behind.
    func testNothingIsLeftStagedAfterADelivery() throws {
        _ = CanvasNoteCourier(mailboxRoot: root).send(
            annotation, on: canvas, along: .mailbox(handle))

        XCTAssertEqual(
            try names().filter { $0.hasPrefix(".tmp-") }, [],
            "a temp file left in someone's mailbox is litter nothing ever cleans up")
    }
}
