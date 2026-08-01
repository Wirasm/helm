import XCTest

@testable import Helm

/// When a terminal-requested desktop notification is delivered. Split out of
/// `TerminalCapabilitiesTests` with the type.
final class TerminalNotifierTests: XCTestCase {

    func testNotificationDeliversUnlessAppActiveAndTabSelected() {
        // The one silent case: the user is already looking at that terminal.
        XCTAssertFalse(
            TerminalNotificationGate.shouldDeliver(appIsActive: true, tabIsSelected: true))

        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: true, tabIsSelected: false))
        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: false, tabIsSelected: true))
        XCTAssertTrue(
            TerminalNotificationGate.shouldDeliver(appIsActive: false, tabIsSelected: false))
    }
}
