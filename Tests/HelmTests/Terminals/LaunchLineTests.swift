import XCTest

@testable import Helm

/// The resume line's two rules, kept from the spool when it retired (M3): every word is quoted,
/// and a resumed claude gets the operator's own unattended posture unless the line already decided.
final class LaunchLineTests: XCTestCase {
    func testQuotingSurvivesAnEmbeddedSingleQuote() {
        XCTAssertEqual(LaunchLine.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(LaunchLine.quoted("; rm -rf /"), "'; rm -rf /'")
    }

    func testAClaudeResumeGetsTheOperatorsPosture() {
        XCTAssertEqual(
            UnattendedPosture.arguments(for: "claude", requested: ["--resume", "x"]),
            ["--dangerously-skip-permissions", "--resume", "x"])
        XCTAssertEqual(
            UnattendedPosture.arguments(for: "codex", requested: ["x"]), ["x"],
            "only a claude conversation is resumed here; benchd owns every spawned posture")
    }

    func testALineThatDecidedForItselfIsLeftAlone() {
        XCTAssertEqual(
            UnattendedPosture.arguments(for: "claude", requested: ["--permission-mode=plan"]),
            ["--permission-mode=plan"])
    }

    func testNoPostureWithholdsCapability() {
        for (command, posture) in UnattendedPosture.postures {
            XCTAssertFalse(
                posture.arguments.contains { ["--no-approve", "-na", "--sandbox"].contains($0) },
                "\(command)'s posture removes a prompt and restrains nothing")
        }
    }
}
