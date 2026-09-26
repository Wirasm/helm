import XCTest

@testable import GhosttyTerminal

/// helm runs one `TerminalController` (one `ghostty_app_t`) with a surface per pane, so a
/// wakeup has to reach every surface on it. A single handler slot let the newest surface steal
/// every other surface's wakeups, and closing any pane stopped the ticks for the rest; helm
/// carried a patch for that until the wrapper grew this registry.
@MainActor
final class WakeupFanOutTests: XCTestCase {
    private final class Token {}

    func testAWakeupReachesEveryObserver() {
        let controller = TerminalController()
        let first = Token()
        let second = Token()
        var firstWakeups = 0
        var secondWakeups = 0
        controller.addWakeupObserver(
            ObjectIdentifier(first), shouldProcess: { true }, onWakeup: { firstWakeups += 1 })
        controller.addWakeupObserver(
            ObjectIdentifier(second), shouldProcess: { true }, onWakeup: { secondWakeups += 1 })

        controller.handleWakeup()

        XCTAssertEqual(firstWakeups, 1)
        XCTAssertEqual(secondWakeups, 1, "the second surface must not steal the first's wakeup")
    }

    func testRemovingOneObserverKeepsTheOthersAwake() {
        let controller = TerminalController()
        let first = Token()
        let second = Token()
        var firstWakeups = 0
        var secondWakeups = 0
        controller.addWakeupObserver(
            ObjectIdentifier(first), shouldProcess: { true }, onWakeup: { firstWakeups += 1 })
        controller.addWakeupObserver(
            ObjectIdentifier(second), shouldProcess: { true }, onWakeup: { secondWakeups += 1 })

        controller.removeWakeupObserver(ObjectIdentifier(second))
        controller.handleWakeup()

        XCTAssertEqual(firstWakeups, 1, "closing one pane must not stall the survivors")
        XCTAssertEqual(secondWakeups, 0)
    }

    func testADetachedSurfaceDoesNotStopTheTickForAnAttachedOne() {
        let controller = TerminalController()
        let attached = Token()
        let detached = Token()
        var attachedWakeups = 0
        controller.addWakeupObserver(
            ObjectIdentifier(detached), shouldProcess: { false }, onWakeup: {})
        controller.addWakeupObserver(
            ObjectIdentifier(attached), shouldProcess: { true }, onWakeup: { attachedWakeups += 1 })

        controller.handleWakeup()

        XCTAssertEqual(attachedWakeups, 1)
    }

    func testEveryObserverSuspendedMeansNoWakeup() {
        let controller = TerminalController()
        let token = Token()
        var wakeups = 0
        controller.addWakeupObserver(
            ObjectIdentifier(token), shouldProcess: { false }, onWakeup: { wakeups += 1 })

        controller.handleWakeup()

        XCTAssertEqual(wakeups, 0)
    }
}
