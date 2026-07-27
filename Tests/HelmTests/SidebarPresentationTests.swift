import XCTest

@testable import Helm

final class SidebarPresentationTests: XCTestCase {
    func testRoomStatusPrecedence() {
        XCTAssertEqual(
            SidebarPresentation.roomStatus(state: "running", hasOpenDecisions: true, live: true),
            .needsYou
        )
        XCTAssertEqual(
            SidebarPresentation.roomStatus(state: "running", hasOpenDecisions: false, live: true),
            .working
        )
        XCTAssertEqual(
            SidebarPresentation.roomStatus(state: "reported", hasOpenDecisions: false, live: true),
            .quiet("reported")
        )
        XCTAssertEqual(
            SidebarPresentation.roomStatus(state: nil, hasOpenDecisions: false, live: true),
            .quiet("unknown")
        )
        XCTAssertEqual(
            SidebarPresentation.roomStatus(state: "running", hasOpenDecisions: false, live: false),
            .quiet("running")
        )
    }

    func testParticipantLivenessPrecedence() {
        XCTAssertEqual(
            SidebarPresentation.participantLiveness(kind: "attached", idle: true, posted: true),
            .attached
        )
        XCTAssertEqual(
            SidebarPresentation.participantLiveness(kind: nil, idle: true, posted: true),
            .idle
        )
        XCTAssertEqual(
            SidebarPresentation.participantLiveness(kind: nil, idle: false, posted: true),
            .reported
        )
        XCTAssertEqual(
            SidebarPresentation.participantLiveness(kind: nil, idle: nil, posted: nil),
            .quiet
        )
    }

    func testModelShortnameOnlyDropsProviderPath() {
        XCTAssertEqual(
            SidebarPresentation.modelShortname("openai-codex/gpt-5.6-terra"),
            "gpt-5.6-terra"
        )
        XCTAssertEqual(SidebarPresentation.modelShortname("sol-4"), "sol-4")
        XCTAssertEqual(SidebarPresentation.modelShortname(nil), "default")
    }
}
