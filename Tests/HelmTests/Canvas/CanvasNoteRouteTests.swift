import HelmWire
import XCTest

@testable import Helm

/// The routing decision on its own — #205's acceptance asks for a test over *the decision*,
/// "not by posting a note by hand", which is what the owner lookup being a closure buys.
///
/// The join it sits inside is `CanvasMarkReachesAgentTests`: a real gesture, the real script, a
/// real mailbox on disk. Both are needed, and #216 is why — a rule and a pipeline were each
/// tested there too, and the thing that shipped broken for months was the seam between them.
final class CanvasNoteRouteTests: XCTestCase {
    private let terminal = CanvasOrigin(terminal: UUID())

    /// `Handle(validating:)!` is the spelling `MailboxOwner`'s own header names for a caller that
    /// wants a specific handle rather than one read off disk.
    private func owner(handle: String, pid: pid_t = 4321) -> MailboxOwner {
        MailboxOwner(
            handle: Handle(validating: handle)!, runtime: "claude", pid: pid,
            sessionId: "e6f1c2d8-0000-4000-8000-0000000611a4", cwd: "/work")
    }

    // MARK: - The three answers

    func testAMarkOnACanvasAnAgentPushedGoesToThatAgentsMailbox() {
        var asked: [CanvasOrigin] = []

        let route = CanvasNoteRoute.route(origin: terminal) { origin in
            asked.append(origin)
            return owner(handle: "sild-611a")
        }

        XCTAssertEqual(route, .mailbox(Handle(validating: "sild-611a")!))
        XCTAssertEqual(
            asked, [terminal],
            "the lookup is asked about the terminal that pushed the canvas and no other")
    }

    /// A canvas the operator opened by hand — ⌘O, a ⌘-clicked link, a restored pane. There is
    /// nobody to route to, and the fallback is the clipboard exactly as before #205.
    func testACanvasNobodyPushedFallsBackToTheClipboard() {
        var asked = false

        let route = CanvasNoteRoute.route(origin: nil) { _ in
            asked = true
            return nil
        }

        XCTAssertEqual(route, .clipboard(.noOrigin))
        XCTAssertFalse(asked, "with no origin there is nothing to look up")
    }

    /// The pane was closed, the session ended, or the agent never claimed a mailbox.
    func testAnOriginWithNoMailboxLeftFallsBackToTheClipboard() {
        XCTAssertEqual(
            CanvasNoteRoute.route(origin: terminal) { _ in nil }, .clipboard(.originGone))
    }

    /// **The two fallbacks are different answers and must stay distinguishable.** From outside
    /// they look identical — no mail either way — and #205 is explicit that a silent no-op is the
    /// worst outcome here, because the operator believes the note was sent. Collapsing them would
    /// leave "why did nothing send?" unanswerable at the one moment it is asked.
    func testTheTwoFallbacksAreNotTheSameFallback() {
        XCTAssertNotEqual(
            CanvasNoteRoute.route(origin: nil) { _ in nil },
            CanvasNoteRoute.route(origin: terminal) { _ in nil })

        XCTAssertEqual(
            CanvasNoteDelivery.notSent(.noOrigin).receipt(sidecar: "plan.notes.md"),
            "Written to plan.notes.md and copied — no agent pushed this canvas, so paste it to one"
        )
        XCTAssertEqual(
            CanvasNoteDelivery.notSent(.originGone).receipt(sidecar: "plan.notes.md"),
            "Written to plan.notes.md and copied — the agent that pushed this canvas is gone, "
                + "so paste it to another")
    }

    // MARK: - The handle

    /// **Read off the owner record, never rebuilt from its parts.** `deriveHandle` widens the
    /// session-id suffix 4 → 6 → 8 → full when a live process already holds the shorter form, and
    /// `HELM_MAIL_HANDLE` short-circuits it entirely — so a handle computed from `cwd` and
    /// `sessionId` is silently wrong exactly when it collides, which is the case nobody tests.
    /// This fixture is one that no derivation would produce.
    func testTheHandleIsWhateverTheOwnerRecordSaysItIs() {
        let pinned = owner(handle: "pinned-by-hand")

        XCTAssertEqual(
            CanvasNoteRoute.route(origin: terminal) { _ in pinned },
            .mailbox(Handle(validating: "pinned-by-hand")!),
            "`work-611a` is what deriving from cwd + session id would give, and it is not this")
    }

    // MARK: - The clipboard

    /// Every outcome there is, so the two tests below cannot quietly stop covering one.
    private var everyDelivery: [CanvasNoteDelivery] {
        [
            .sent(Handle(validating: "sild-611a")!),
            .notSent(.noOrigin),
            .notSent(.originGone),
            .failed(Handle(validating: "sild-611a")!, "there is no mailbox at sild-611a any more"),
        ]
    }

    /// **The case that changes (#303), and the only one.** The agent already has the note, so
    /// replacing the operator's clipboard with a second copy of it buys nothing and costs them
    /// whatever they were about to paste. *Copy when the copy is the delivery* — here it is not.
    func testANoteTheAgentReceivedIsNotAlsoTakenToTheOperatorsClipboard() {
        XCTAssertFalse(
            CanvasNoteDelivery.sent(Handle(validating: "sild-611a")!).copiesToClipboard,
            "a delivered note has a mailbox and a sidecar; the clipboard is somebody else's")
    }

    /// **Control.** Nobody pushed this canvas, so there is no mailbox to reach and the clipboard
    /// **is** the return path — take it away and the note reaches nobody at all. Named as a control
    /// because the change above, overshot into "never copy", would satisfy the test above on its
    /// own; this and the two below are what forbid that.
    func testANoteWithNoAgentToSendToStillGoesToTheClipboard() {
        XCTAssertTrue(CanvasNoteDelivery.notSent(.noOrigin).copiesToClipboard)
    }

    /// **Control**, for the same reason: the pane was closed or the session ended, and the operator
    /// still needs a way to hand the note to somebody.
    func testANoteWhoseAgentIsGoneStillGoesToTheClipboard() {
        XCTAssertTrue(CanvasNoteDelivery.notSent(.originGone).copiesToClipboard)
    }

    /// **Control**, and the sharpest of the three — delivery was *attempted* and failed, which is
    /// the case most easily mistaken for `sent`. Stranding the note is worse than the pollution.
    func testANoteThatCouldNotBeDeliveredStillGoesToTheClipboard() {
        let failed = CanvasNoteDelivery.failed(Handle(validating: "sild-611a")!, "no mailbox")

        XCTAssertTrue(
            failed.copiesToClipboard,
            "a failed send is not a send — the note has to end up somewhere reachable")
    }

    // MARK: - The receipt

    /// **A receipt names the clipboard exactly when the clipboard was written**, over every case
    /// there is. The reason the receipt says so at all is unchanged and still right — the operator
    /// has to know their clipboard just changed under them — so the defect this forbids has two
    /// directions: a copy the receipt is silent about, and a receipt claiming a copy that never
    /// happened. Both read as lies about state the operator cannot see.
    func testAReceiptSaysCopiedExactlyWhenTheNoteWasCopied() {
        for delivery in everyDelivery {
            let receipt = delivery.receipt(sidecar: "plan.notes.md")
            XCTAssertEqual(
                receipt.lowercased().contains("copied"), delivery.copiesToClipboard,
                "\(receipt) disagrees with copiesToClipboard == \(delivery.copiesToClipboard)")
        }
    }

    func testEveryReceiptNamesTheSidecarAndWhereTheNoteWent() {
        let receipts = everyDelivery.map { $0.receipt(sidecar: "plan.notes.md") }

        for receipt in receipts {
            XCTAssertTrue(
                receipt.contains("plan.notes.md"), "\(receipt) does not name the sidecar")
        }
        XCTAssertEqual(receipts[0], "Written to plan.notes.md and sent to sild-611a")
        XCTAssertTrue(
            receipts[3].contains("could not reach sild-611a"),
            "a delivery that failed must not read like one that worked")
    }
}
