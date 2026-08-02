import XCTest

@testable import Helm

/// The composer's gate, stated once more against the thing that would break it.
///
/// This suite exists because the failure is silent and expensive: prose typed
/// into a live permission prompt had its first character approve and run a
/// network command (#29), with no error and nothing to undo. The guard is one
/// comparison, and the way it breaks is somebody "simplifying" it to the
/// board's own `isWorking`.
@MainActor
final class ChatComposerGateTests: XCTestCase {
    /// The exact set. If a fifth status ever appears, this fails rather than
    /// quietly admitting it — a status this build has never heard of decodes to
    /// `nil`, and `nil` must not open the box.
    func testOnlyIdleOpensTheComposer() {
        let open = AgentStatus.everyPublishedStatus.filter { status in
            model(status).canSend
        }
        XCTAssertEqual(open, [.idle])
    }

    /// **The load-bearing disagreement.** `AgentStatus.isWorking` answers the
    /// board's question — "does this need you?" — and folds `waiting` in with
    /// `idle` because both mean it is your turn. The composer asks "is it safe to
    /// write into the pty?", where `waiting` is the one case that is definitely
    /// not. Spelling the gate `!isWorking` would open it on exactly that case.
    func testTheGateIsNotTheBoardsCollapse() {
        for status in AgentStatus.everyPublishedStatus {
            let subject = model(status)
            if status == .waiting {
                XCTAssertFalse(subject.isWorking == false && subject.canSend)
                XCTAssertNotEqual(
                    subject.canSend, !status.isWorking,
                    "the board would say 'your turn' here; the composer must still refuse")
            } else {
                XCTAssertEqual(subject.canSend, !status.isWorking)
            }
        }
    }

    /// An agent blocked on a prompt is mid-turn, so the tape keeps running even
    /// though the board would call it stopped.
    func testTheTickerAndTheComposerDisagreeAboutWaiting() {
        let waiting = model(.waiting)
        XCTAssertTrue(waiting.isWorking, "mid-turn — the tape is still going")
        XCTAssertFalse(waiting.canSend, "and the box is still shut")
    }

    func testNoAgentAtAllIsNotALicenceToType() {
        XCTAssertFalse(ChatModel().canSend)
    }

    /// Builds a model whose only published state is the status under test.
    private func model(_ status: AgentStatus) -> ChatModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-gate-\(UUID().uuidString)")
        let registry = base.appendingPathComponent("sessions")
        try! FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try! """
        {"pid":4242,"sessionId":"s","cwd":"/tmp/ws","status":"\(status.rawValue)"}
        """.write(
            to: registry.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)

        let subject = ChatModel(
            registryRoot: registry, transcriptRoot: base.appendingPathComponent("projects"))
        subject.tick(foregroundPid: 4242)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return subject
    }
}

extension AgentStatus {
    /// Every status Claude Code publishes, so the gate is asserted against all of
    /// them rather than the three somebody happened to think of.
    ///
    /// Built through an exhaustive `switch` rather than a bare array literal: a
    /// fifth case added to `AgentStatus` then fails to compile *here*, instead of
    /// quietly slipping past a test that claims to cover everything.
    static var everyPublishedStatus: [AgentStatus] {
        [AgentStatus.busy, .shell, .idle, .waiting].map { status in
            switch status {
            case .busy: .busy
            case .shell: .shell
            case .idle: .idle
            case .waiting: .waiting
            }
        }
    }
}
