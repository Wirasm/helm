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

    // MARK: - The receipt

    /// Every case names the clipboard, because every case copies — the clipboard was the whole
    /// return path before #205 and a routed note must not quietly take it away.
    func testEveryReceiptSaysWhereTheNoteWentAndThatTheClipboardChanged() {
        let receipts = [
            CanvasNoteDelivery.sent(Handle(validating: "sild-611a")!),
            .notSent(.noOrigin),
            .notSent(.originGone),
            .failed(Handle(validating: "sild-611a")!, "there is no mailbox at sild-611a any more"),
        ].map { $0.receipt(sidecar: "plan.notes.md") }

        for receipt in receipts {
            XCTAssertTrue(
                receipt.contains("plan.notes.md"), "\(receipt) does not name the sidecar")
            XCTAssertTrue(
                receipt.lowercased().contains("copied"),
                "\(receipt) does not say the clipboard changed under the operator")
        }
        XCTAssertTrue(receipts[0].contains("sent to sild-611a"))
        XCTAssertTrue(
            receipts[3].contains("could not reach sild-611a"),
            "a delivery that failed must not read like one that worked")
    }
}
