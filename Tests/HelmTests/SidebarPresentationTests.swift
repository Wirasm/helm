import XCTest

@testable import Helm

/// Formatting shared by the observe column and the dock.
///
/// This file previously covered four behaviours of the room-era sidebar. Two survived the
/// rename because they format facts; two were deleted with the concepts they read:
///
/// - `testRoomStatusPrecedence` covered `roomStatus(hasOpenDecisions:)`. Open decisions were
///   the `needs-decision` protocol, which moved to PRP — the engine no longer reports them,
///   so there is no precedence left to test. Attention is now `Agent.idle`, covered in
///   `AttentionTests`.
/// - `testParticipantLivenessPrecedence` covered
///   `participantLiveness(kind:idle:posted:)`. `posted` was deleted outright, and `kind`
///   became `ownership` with different semantics. `AttentionTests` and `ConversationTests`
///   cover what replaced it.
///
/// Neither was removed to make a gate pass; both describe behaviour that no longer exists.
final class SidebarPresentationTests: XCTestCase {

    /// Two kilds touching the same file is ONE file in conflict. Count and detail are
    /// derived from a single set so a badge can never disagree with the list beneath it.
    func testCollisionSummaryUsesOneUniqueFileSetForCountAndHelp() {
        let summary = KildPresentation.collisionSummary([
            Collision(other: "b", otherName: "beta", files: ["shared.swift"]),
            Collision(
                other: "c", otherName: "charlie",
                files: ["Sources/A.swift", "shared.swift"]),
        ])

        XCTAssertEqual(summary.names, "beta, charlie")
        XCTAssertEqual(summary.files, ["Sources/A.swift", "shared.swift"])
        XCTAssertEqual(summary.count, summary.files.count)
        XCTAssertEqual(summary.count, 2, "shared.swift is one conflict, not two")
    }

    func testModelShortnameOnlyDropsProviderPath() {
        XCTAssertEqual(
            KildPresentation.modelShortname("openai-codex/gpt-5.6-terra"), "gpt-5.6-terra")
        XCTAssertEqual(KildPresentation.modelShortname("sol-4"), "sol-4")
        XCTAssertEqual(KildPresentation.modelShortname(nil), "default")
    }
}
